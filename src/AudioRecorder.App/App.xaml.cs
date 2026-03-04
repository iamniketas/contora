using AudioRecorder.Core.Models;
using AudioRecorder.Views;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using System.Reflection;
using System.Runtime.InteropServices;
using Velopack;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace AudioRecorder
{
    /// <summary>
    /// Provides application-specific behavior to supplement the default Application class.
    /// </summary>
    public partial class App : Application
    {
        private Window window = Window.Current;
        private AppWindow? _appWindow;
        private DispatcherQueue _dispatcherQueue = DispatcherQueue.GetForCurrentThread();

        private Forms.NotifyIcon? _notifyIcon;
        private Forms.ToolStripMenuItem? _showHideMenuItem;
        private Forms.ToolStripMenuItem? _toggleRecordingMenuItem;
        private Forms.ToolStripMenuItem? _togglePauseMenuItem;

        private bool _isExitRequested;
        private nint _smallTitleBarIcon;
        private nint _bigTitleBarIcon;

        private const int WM_SETICON = 0x0080;
        private const int ICON_SMALL = 0;
        private const int ICON_BIG = 1;
        private const uint IMAGE_ICON = 1;
        private const uint LR_LOADFROMFILE = 0x0010;
        private const uint LR_DEFAULTSIZE = 0x0040;

        /// <summary>
        /// Main application window.
        /// </summary>
        public static Window? MainWindow { get; private set; }

        /// <summary>
        /// Settings window singleton (null when closed).
        /// </summary>
        public static Views.SettingsWindow? SettingsWindowInstance { get; set; }

        /// <summary>
        /// Initializes the singleton application object.
        /// </summary>
        public App()
        {
            // Required for Velopack install/update hooks.
            VelopackApp.Build().Run();
            InitializeComponent();
        }

        /// <summary>
        /// Invoked when the application is launched normally by the end user.
        /// </summary>
        protected override void OnLaunched(LaunchActivatedEventArgs e)
        {
            string logPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Contora",
                "logs",
                "app.log");

            AudioRecorder.Services.Logging.AppLogger.Initialize(logPath);
            AudioRecorder.Services.Logging.AppLogger.LogInfo("Application started");

            window ??= new Window();
            MainWindow = window;
            _dispatcherQueue = DispatcherQueue.GetForCurrentThread();

            if (window.Content is not Frame rootFrame)
            {
                rootFrame = new Frame();
                rootFrame.NavigationFailed += OnNavigationFailed;
                window.Content = rootFrame;
            }

            _ = rootFrame.Navigate(typeof(MainPage), e.Arguments);

            window.Title = BuildWindowTitle();
            ApplyWindowIcon(window);
            InitializeWindowBehavior(window);
            InitializeTrayIcon();

            window.Activate();
            _dispatcherQueue.TryEnqueue(() => ApplyWindowIcon(window));
        }

        private static string BuildWindowTitle()
        {
            string version = GetAppVersion();
            return string.IsNullOrWhiteSpace(version) ? "Contora" : $"Contora {version}";
        }

        private static string GetAppVersion()
        {
            string? informationalVersion = Assembly.GetExecutingAssembly()
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
                .InformationalVersion;

            if (!string.IsNullOrWhiteSpace(informationalVersion))
            {
                int metadataIndex = informationalVersion.IndexOf('+');
                return metadataIndex > 0
                    ? informationalVersion[..metadataIndex]
                    : informationalVersion;
            }

            Version? version = Assembly.GetExecutingAssembly().GetName().Version;
            return version is null
                ? string.Empty
                : $"{version.Major}.{version.Minor}.{Math.Max(version.Build, 0)}";
        }

        private void ApplyWindowIcon(Window appWindow)
        {
            try
            {
                string iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "Contora.ico");
                if (!File.Exists(iconPath))
                {
                    return;
                }

                IntPtr hWnd = WinRT.Interop.WindowNative.GetWindowHandle(appWindow);
                var windowId = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(hWnd);
                _appWindow ??= AppWindow.GetFromWindowId(windowId);
                _appWindow.SetIcon(iconPath);
                ApplyNativeWindowIcons(hWnd, iconPath);
            }
            catch
            {
                // Non-critical: keep startup working even if icon binding fails.
            }
        }

        private void ApplyNativeWindowIcons(nint hWnd, string iconPath)
        {
            if (_smallTitleBarIcon == 0)
            {
                _smallTitleBarIcon = LoadImage(
                    IntPtr.Zero,
                    iconPath,
                    IMAGE_ICON,
                    16,
                    16,
                    LR_LOADFROMFILE | LR_DEFAULTSIZE);
            }

            if (_bigTitleBarIcon == 0)
            {
                _bigTitleBarIcon = LoadImage(
                    IntPtr.Zero,
                    iconPath,
                    IMAGE_ICON,
                    32,
                    32,
                    LR_LOADFROMFILE | LR_DEFAULTSIZE);
            }

            if (_smallTitleBarIcon != 0)
            {
                SendMessage(hWnd, WM_SETICON, ICON_SMALL, _smallTitleBarIcon);
            }

            if (_bigTitleBarIcon != 0)
            {
                SendMessage(hWnd, WM_SETICON, ICON_BIG, _bigTitleBarIcon);
            }
        }

        private void InitializeWindowBehavior(Window appWindow)
        {
            IntPtr hWnd = WinRT.Interop.WindowNative.GetWindowHandle(appWindow);
            var windowId = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(hWnd);
            _appWindow = AppWindow.GetFromWindowId(windowId);
            _appWindow.Closing += OnAppWindowClosing;
            _appWindow.Changed += OnAppWindowChanged;
        }

        private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
        {
            if (_isExitRequested)
            {
                CleanupTrayIcon();
                return;
            }

            args.Cancel = true;
            HideToTray();
        }

        private void OnAppWindowChanged(AppWindow sender, AppWindowChangedEventArgs args)
        {
            if (_appWindow?.Presenter is OverlappedPresenter presenter && presenter.State == OverlappedPresenterState.Minimized)
            {
                HideToTray();
            }
        }

        private void InitializeTrayIcon()
        {
            try
            {
                string exePath = Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Contora.exe");
                Drawing.Icon trayIcon = File.Exists(exePath)
                    ? (Drawing.Icon.ExtractAssociatedIcon(exePath) ?? Drawing.SystemIcons.Application)
                    : Drawing.SystemIcons.Application;

                var contextMenu = new Forms.ContextMenuStrip();
                contextMenu.Opening += (_, _) => UpdateTrayMenuState();

                _showHideMenuItem = new Forms.ToolStripMenuItem("Show window", null, (_, _) => ToggleWindowVisibilityFromTray());
                _toggleRecordingMenuItem = new Forms.ToolStripMenuItem("Start recording", null, (_, _) => ToggleRecordingFromTray());
                _togglePauseMenuItem = new Forms.ToolStripMenuItem("Pause", null, (_, _) => TogglePauseFromTray());
                var exitMenuItem = new Forms.ToolStripMenuItem("Exit", null, (_, _) => ExitFromTray());

                contextMenu.Items.Add(_showHideMenuItem);
                contextMenu.Items.Add(new Forms.ToolStripSeparator());
                contextMenu.Items.Add(_toggleRecordingMenuItem);
                contextMenu.Items.Add(_togglePauseMenuItem);
                contextMenu.Items.Add(new Forms.ToolStripSeparator());
                contextMenu.Items.Add(exitMenuItem);

                _notifyIcon = new Forms.NotifyIcon
                {
                    Icon = trayIcon,
                    Visible = true,
                    Text = "Contora",
                    ContextMenuStrip = contextMenu
                };

                _notifyIcon.DoubleClick += (_, _) => ShowFromTray();
                UpdateTrayMenuState();
            }
            catch
            {
                // Keep app working if tray icon initialization fails.
            }
        }

        private void UpdateTrayMenuState()
        {
            if (_showHideMenuItem == null || _toggleRecordingMenuItem == null || _togglePauseMenuItem == null)
            {
                return;
            }

            var page = GetMainPage();
            bool isVisible = _appWindow?.IsVisible ?? true;

            _showHideMenuItem.Text = isVisible ? "Hide window" : "Show window";

            if (page == null)
            {
                _toggleRecordingMenuItem.Enabled = false;
                _togglePauseMenuItem.Enabled = false;
                return;
            }

            var (state, hasSelection) = page.GetTrayStateSnapshot();

            _toggleRecordingMenuItem.Text = state == RecordingState.Stopped ? "Start recording" : "Stop recording";
            _toggleRecordingMenuItem.Enabled = state != RecordingState.Stopped || hasSelection;

            _togglePauseMenuItem.Text = state == RecordingState.Paused ? "Resume" : "Pause";
            _togglePauseMenuItem.Enabled = state != RecordingState.Stopped;
        }

        private void ToggleWindowVisibilityFromTray()
        {
            _dispatcherQueue.TryEnqueue(() =>
            {
                if (_appWindow?.IsVisible == true)
                {
                    HideToTray();
                }
                else
                {
                    ShowFromTray();
                }
            });
        }

        private void ToggleRecordingFromTray()
        {
            _dispatcherQueue.TryEnqueue(() =>
            {
                var page = GetMainPage();
                page?.ToggleRecordingFromTray();
                UpdateTrayMenuState();
            });
        }

        private void TogglePauseFromTray()
        {
            _dispatcherQueue.TryEnqueue(() =>
            {
                var page = GetMainPage();
                page?.TogglePauseFromTray();
                UpdateTrayMenuState();
            });
        }

        private void ShowFromTray()
        {
            _dispatcherQueue.TryEnqueue(() =>
            {
                if (_appWindow == null)
                {
                    return;
                }

                if (_appWindow.Presenter is OverlappedPresenter presenter && presenter.State == OverlappedPresenterState.Minimized)
                {
                    presenter.Restore();
                }

                _appWindow.Show();
                window.Activate();
                UpdateTrayMenuState();
            });
        }

        private void HideToTray()
        {
            _dispatcherQueue.TryEnqueue(() =>
            {
                _appWindow?.Hide();
                UpdateTrayMenuState();
            });
        }

        private void ExitFromTray()
        {
            _dispatcherQueue.TryEnqueue(() =>
            {
                _isExitRequested = true;
                CleanupTrayIcon();
                window.Close();
            });
        }

        private MainPage? GetMainPage()
        {
            if (window.Content is Frame frame)
            {
                return frame.Content as MainPage;
            }

            return null;
        }

        private void CleanupTrayIcon()
        {
            try
            {
                if (_notifyIcon != null)
                {
                    _notifyIcon.Visible = false;
                    _notifyIcon.Dispose();
                    _notifyIcon = null;
                }

                if (_smallTitleBarIcon != 0)
                {
                    DestroyIcon(_smallTitleBarIcon);
                    _smallTitleBarIcon = 0;
                }

                if (_bigTitleBarIcon != 0)
                {
                    DestroyIcon(_bigTitleBarIcon);
                    _bigTitleBarIcon = 0;
                }
            }
            catch
            {
                // Ignore cleanup errors.
            }
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern nint LoadImage(
            nint hInst,
            string lpszName,
            uint uType,
            int cxDesired,
            int cyDesired,
            uint fuLoad);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern nint SendMessage(nint hWnd, int msg, nint wParam, nint lParam);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DestroyIcon(nint hIcon);

        /// <summary>
        /// Invoked when navigation to a certain page fails.
        /// </summary>
        private static void OnNavigationFailed(object sender, NavigationFailedEventArgs e)
        {
            throw new Exception("Failed to load Page " + e.SourcePageType.FullName);
        }
    }
}
