using System;
using static Backgrounds.Native;

namespace Backgrounds
{
    /// <summary>
    /// Puts windows behind the desktop icons (no Wallpaper Engine needed). The technique used by Lively Wallpaper:
    ///
    /// Classic desktop (Windows 10, Windows 11 before 24H2): sending 0x052C to Progman makes Explorer split the
    /// desktop into the icons layer (a WorkerW holding SHELLDLL_DefView) and an empty WorkerW behind it.
    /// Our windows become children of that empty WorkerW.
    ///
    /// "Raised" desktop (Windows 11 24H2+; Progman has WS_EX_NOREDIRECTIONBITMAP): the icons (SHELLDLL_DefView) and
    /// Explorer's wallpaper (a WorkerW) are both children of Progman. Per Microsoft's guidance our window must be a
    /// WS_EX_LAYERED child of Progman (alpha 255), z-ordered below SHELLDLL_DefView and above that WorkerW.
    /// </summary>
    static class Desktop
    {
        public static IntPtr Progman { get; private set; }
        public static IntPtr WorkerW { get; private set; }
        public static IntPtr DefView { get; private set; }
        public static bool Raised { get; private set; }

        /// The window our wallpapers are children of.
        public static IntPtr Parent => Raised ? Progman : WorkerW;

        public static bool Setup()
        {
            Progman = FindWindow("Progman", null);
            WorkerW = DefView = IntPtr.Zero;
            if (Progman == IntPtr.Zero) { Log.Write("Progman not found (is Explorer running?)"); return false; }
            Raised = (GetWindowLong(Progman, GWL_EXSTYLE) & WS_EX_NOREDIRECTIONBITMAP) != 0;

            // Ask Explorer to create the WorkerW behind the icons. One message (0xD, 0x1), as Lively does: the older
            // two-message sequence removes the freshly created layer on raised desktops.
            SendMessageTimeout(Progman, 0x052C, new IntPtr(0xD), new IntPtr(0x1), SMTO_NORMAL, 1000, out _);

            if (Raised)
            {
                DefView = FindWindowEx(Progman, IntPtr.Zero, "SHELLDLL_DefView", null);
                WorkerW = FindWindowEx(Progman, IntPtr.Zero, "WorkerW", null);
            }
            else
            {
                // Find the top-level window that holds SHELLDLL_DefView; the WorkerW right after it is ours.
                EnumWindows((top, _) =>
                {
                    IntPtr p = FindWindowEx(top, IntPtr.Zero, "SHELLDLL_DefView", null);
                    if (p != IntPtr.Zero)
                    {
                        DefView = p;
                        WorkerW = FindWindowEx(IntPtr.Zero, top, "WorkerW", null);
                    }
                    return true;
                }, IntPtr.Zero);
            }
            Log.Write($"Desktop: raised={Raised} progman={Progman} workerw={WorkerW} defview={DefView}");
            return Raised ? DefView != IntPtr.Zero : WorkerW != IntPtr.Zero;
        }

        /// Is the layout we attached to still there? (Explorer restarts / crashes destroy it.)
        public static bool StillValid()
        {
            if (!IsWindow(Progman) || FindWindow("Progman", null) != Progman) return false;
            if (Raised) return IsWindow(DefView) && GetParent(DefView) == Progman;
            return IsWindow(WorkerW);
        }

        /// Makes `hwnd` (a top-level window created with WS_EX_LAYERED when Raised) a desktop child.
        public static bool Attach(IntPtr hwnd)
        {
            if (Raised)
            {
                uint style = GetWindowLong(hwnd, GWL_STYLE);
                SetWindowLong(hwnd, GWL_STYLE, (style & ~WS_POPUP) | WS_CHILD);
                uint ex = GetWindowLong(hwnd, GWL_EXSTYLE);
                if ((ex & WS_EX_LAYERED) == 0) SetWindowLong(hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED);
                SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);
                if (SetParent(hwnd, Progman) == IntPtr.Zero) { Log.Write("SetParent(Progman) failed"); return false; }
                SetWindowPos(hwnd, DefView, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
                EnsureWorkerWAtBottom();
            }
            else
            {
                if (SetParent(hwnd, WorkerW) == IntPtr.Zero) { Log.Write("SetParent(WorkerW) failed"); return false; }
            }
            return true;
        }

        /// Positions an attached window over a screen rectangle given in screen (physical pixel) coordinates.
        public static void Place(IntPtr hwnd, System.Drawing.Rectangle screenBounds)
        {
            var pt = new POINT { X = screenBounds.Left, Y = screenBounds.Top };
            MapWindowPoints(IntPtr.Zero, Parent, ref pt, 1);   // screen -> parent client coordinates
            SetWindowPos(hwnd, IntPtr.Zero, pt.X, pt.Y, screenBounds.Width, screenBounds.Height,
                SWP_NOACTIVATE | SWP_NOZORDER | SWP_SHOWWINDOW);
        }

        /// On raised desktops Explorer's wallpaper WorkerW must stay the bottom child of Progman, under our windows.
        public static void EnsureWorkerWAtBottom()
        {
            if (!Raised || WorkerW == IntPtr.Zero || !IsWindow(WorkerW)) return;
            IntPtr first = GetWindow(Progman, GW_CHILD);
            if (first == IntPtr.Zero) return;
            if (GetWindow(first, GW_HWNDLAST) != WorkerW)
                SetWindowPos(WorkerW, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }

        /// Our window is still where it should be (right parent; on raised desktops, under the icons).
        public static bool IsAttached(IntPtr hwnd)
        {
            if (!IsWindow(hwnd) || GetParent(hwnd) != Parent) return false;
            if (!Raised) return true;
            // Walk the z-order from DefView downwards: we must come before Explorer's WorkerW.
            for (IntPtr w = GetWindow(DefView, GW_HWNDNEXT); w != IntPtr.Zero; w = GetWindow(w, GW_HWNDNEXT))
            {
                if (w == hwnd) return true;
                if (w == WorkerW) return false;
            }
            return false;
        }

        public static void Restack(IntPtr hwnd)
        {
            if (!Raised) return;
            SetWindowPos(hwnd, DefView, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            EnsureWorkerWAtBottom();
        }
    }
}
