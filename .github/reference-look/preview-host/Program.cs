using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Windows.Forms;
using System.Xml.Linq;
using mRemoteNG.App;
using mRemoteNG.Config.Serializers.ConnectionSerializers.Xml;
using mRemoteNG.Connection;
using mRemoteNG.Connection.Protocol;
using mRemoteNG.Container;
using mRemoteNG.Security;
using mRemoteNG.Security.SymmetricEncryption;
using mRemoteNG.Themes;
using mRemoteNG.Tree;
using mRemoteNG.Tree.Root;
using mRemoteNG.UI.Forms;
using mRemoteNG.UI.Window;
using WeifenLuo.WinFormsUI.Docking;

internal static class Program
{
    private static string _output = "";
    private static string _theme = "Catppuccin Mocha Comfortable";
    private static bool _disabled;
    private static bool _finished;
    private static Exception? _failure;
    private static int _stage;
    private static bool _ticking;
    private static bool _holdingMenuForCapture;
    private static ToolStripDropDown? _captureMenu;
    private static Control? _connectingPreview;
    private static readonly Stopwatch Elapsed = Stopwatch.StartNew();
    private static readonly Assembly AppAssembly = typeof(ProgramRoot).Assembly;

    [STAThread]
    private static int Main(string[] args)
    {
        // This utility must never load a person's normal app configuration or connections.
        bool localFixture = args.Contains("--isolated-local-test")
            && File.Exists(Path.Combine(AppContext.BaseDirectory, ".appearance-preview-isolated"));
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" && !localFixture)
        {
            Console.Error.WriteLine("Use a disposable GitHub runner or an explicitly marked isolated local fixture.");
            return 2;
        }
        AppDomain.CurrentDomain.AssemblyResolve += (_, request) =>
        {
            string name = new AssemblyName(request.Name).Name + ".dll";
            foreach (string folder in new[] { AppContext.BaseDirectory, Path.Combine(AppContext.BaseDirectory, "Assemblies"), Path.Combine(AppContext.BaseDirectory, "Plugins") })
            {
                string path = Path.Combine(folder, name);
                if (File.Exists(path)) return Assembly.LoadFrom(path);
            }
            return null;
        };
        return Run(args);
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static int Run(string[] args)
    {
        try
        {
            if (typeof(ProgramRoot).GetProperty("IsPortableBuild", BindingFlags.Static | BindingFlags.NonPublic)!.GetValue(null) is not true)
                throw new InvalidOperationException("The screenshot helper requires a portable app build.");
            _output = Path.GetFullPath(args[0]); Directory.CreateDirectory(_output);
            ConfigureFixtureLogging();
            if (args.Contains("--light")) _theme = "vs2015Light";
            _disabled = args.Contains("--disabled");
            if (_disabled) _theme = "vs2015Light";
            Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            Thread.CurrentThread.CurrentCulture = CultureInfo.GetCultureInfo("en-US");
            Thread.CurrentThread.CurrentUICulture = CultureInfo.GetCultureInfo("en-US");
            Set("OptionsThemePage", "ThemeName", _theme);
            Set("OptionsThemePage", "ThemingActive", !_disabled);
            Set("OptionsThemePage", "IsActiveThemeDark", _theme == "Catppuccin Mocha Comfortable");
            Set("OptionsAdvancedPage", "UseUserProfiles", false);
            Set("OptionsAdvancedPage", "NoReconnect", true);
            Set("OptionsStartupExitPage", "SingleInstance", false);
            Set("OptionsStartupExitPage", "OpenConsFromLastSession", false);
            Set("OptionsStartupExitPage", "SaveConnectionsOnExit", false);
            Set("OptionsUpdatesPage", "CheckForUpdatesAsked", true);
            Set("OptionsUpdatesPage", "CheckForUpdatesOnStartup", false);
            Set("OptionsBackupPage", "SaveConsOnExit", false);
            Set("OptionsBackupPage", "SaveConnectionsAfterEveryEdit", false);
            Set("OptionsNotificationsPage", "LogToApplicationDirectory", true);
            Set("OptionsNotificationsPage", "LogToSyslog", false);

            Set("App", "FirstStart", true);
            Set("App", "DoUpgrade", false);
            Set("OptionsBackupPage", "LoadConsFromCustomLocation", false);
            Set("OptionsConnectionsPage", "ConnectionFilePath", "");
            System.Windows.Forms.Timer? timer = null;
            using CancellationTokenSource stop = new();
            // Starting a WinForms timer creates a native window. Wait for the app
            // to initialize its exception mode and show its own main window first.
            Thread observer = new(() => AttachWhenReady(stop.Token, () =>
            {
                if (stop.IsCancellationRequested) return;
                timer = new System.Windows.Forms.Timer { Interval = 600 };
                timer.Tick += (_, _) => Tick(timer);
                timer.Start();
            })) { IsBackground = true };
            observer.Start();
            try { ProgramRoot.Main(new[] { "--skip-runtime-checks", "/noreconnect" }); }
            finally { stop.Cancel(); observer.Join(1500); timer?.Dispose(); }
            if (_failure != null) throw _failure;
            if (!_finished) throw new InvalidOperationException("The real app closed before the screenshots completed.");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); if (_output.Length > 0) File.WriteAllText(Path.Combine(_output, "preview-error.txt"), error.ToString()); return 1; }
    }

    private static void ConfigureFixtureLogging()
    {
        // The shipped log4net file initially targets APPDATA, even in a portable
        // build. Keep every logger in this disposable app directory instead.
        string path = Path.Combine(AppContext.BaseDirectory, "log4net.config");
        XElement config = XElement.Load(path);
        foreach (XElement file in config.Descendants("file"))
            file.SetAttributeValue("value", Path.Combine(AppContext.BaseDirectory, "appearance-preview.log"));
        config.Save(path);
        new XDocument(new XElement("configuration",
            new XElement("configSections", new XElement("section", new XAttribute("name", "log4net"),
                new XAttribute("type", "log4net.Config.Log4NetConfigurationSectionHandler, log4net"))),
            new XElement("log4net", new XElement("root", new XElement("level", new XAttribute("value", "OFF"))))))
            .Save(Path.Combine(AppContext.BaseDirectory, "AppearancePreview.dll.config"));
    }

    private static void AttachWhenReady(CancellationToken stop, Action attach)
    {
        while (!stop.IsCancellationRequested)
        {
            try
            {
                FrmMain? form = Application.OpenForms.OfType<FrmMain>().FirstOrDefault();
                if (form != null && form.IsHandleCreated && form.Visible && !form.IsDisposed)
                {
                    form.BeginInvoke(attach);
                    return;
                }
            }
            catch (InvalidOperationException) { /* The forms collection/handle can change during startup. */ }
            if (Elapsed.Elapsed > TimeSpan.FromSeconds(75))
            {
                _failure = new TimeoutException("The real app did not show its main window.");
                Console.Error.WriteLine(_failure);
                return;
            }
            Thread.Sleep(100);
        }
    }

    private static void Set(string page, string key, object value)
    {
        Type type = AppAssembly.GetType("mRemoteNG.Properties." + page, true)!;
        object settings = type.GetProperty("Default", BindingFlags.Public | BindingFlags.Static)!.GetValue(null)!;
        type.GetProperty(key, BindingFlags.Public | BindingFlags.Instance)!.SetValue(settings, value);
        type.GetMethod("Save", BindingFlags.Public | BindingFlags.Instance)!.Invoke(settings, null);
    }

    private static object Window(string name) => AppAssembly.GetType("mRemoteNG.App.AppWindows", true)!
        .GetProperty(name, BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic)!.GetValue(null)!;

    private static void Tick(System.Windows.Forms.Timer timer)
    {
        if (_ticking) return;
        _ticking = true;
        timer.Stop();
        try
        {
            Console.WriteLine($"Capture stage {_stage}: begin");
            if (Elapsed.Elapsed > TimeSpan.FromSeconds(75)) throw new TimeoutException("Real app startup/screenshot timeout.");
            FrmMain? form = Application.OpenForms.OfType<FrmMain>().FirstOrDefault();
            if (form == null || !form.Visible || !form.IsHandleCreated || Runtime.WindowList == null) return;
            if (_stage == 0)
            {
                RootNodeInfo? root = Runtime.ConnectionsService.ConnectionTreeModel?.RootNodes.OfType<RootNodeInfo>().FirstOrDefault();
                if (root == null) return; // wait for the normal empty first-run file to finish loading
                ThemeManager manager = ThemeManager.getInstance();
                manager.ActiveTheme = manager.getTheme(_theme) ?? throw new InvalidOperationException($"Theme not found: {_theme}");
                manager.ThemingActive = !_disabled;
                ContainerInfo development = new() { Name = "Development" };
                ContainerInfo production = new() { Name = "Production" };
                ConnectionInfo selected = new() { Name = "app-demo", Hostname = "", Protocol = ProtocolType.RDP, Icon = "mRemoteNG" };
                development.AddChild(selected);
                development.AddChild(new ConnectionInfo { Name = "database-demo", Hostname = "", Protocol = ProtocolType.RDP, Icon = "mRemoteNG" });
                production.AddChild(new ConnectionInfo { Name = "app-example", Hostname = "", Protocol = ProtocolType.RDP, Icon = "mRemoteNG" });
                root.AddChild(development); root.AddChild(production);
                Rectangle screen = Screen.PrimaryScreen!.WorkingArea;
                form.WindowState = FormWindowState.Normal;
                form.Bounds = new Rectangle(screen.Left + 5, screen.Top + 5, Math.Min(1280, screen.Width - 10), Math.Min(900, screen.Height - 10));
                ConnectionTreeWindow tree = (ConnectionTreeWindow)Window("TreeForm");
                tree.ConnectionTree.ExpandAll();
                tree.ConnectionTree.SelectedObject = selected;
                ((ConfigWindow)Window("ConfigForm")).SelectedTreeNode = selected;
                DockPanel dock = (DockPanel)typeof(FrmMain).GetField("pnlDock", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(form)!;
                tree.Show(dock, DockState.DockLeft);
                ((ConfigWindow)Window("ConfigForm")).Show(tree.Pane, DockAlignment.Bottom, 0.5);
                dock.DockLeftPortion = 235 * form.DeviceDpi / 96d;
                tree.Activate();
                DockContent document = new() { Text = "Connecting preview (no server)" };
                Color back = manager.ActiveAndExtended ? manager.ActiveTheme.ExtendedPalette.getColor("Tab_Item_Background") : SystemColors.Control;
                Color fore = manager.ActiveAndExtended ? manager.ActiveTheme.ExtendedPalette.getColor("Dialog_Foreground") : SystemColors.ControlText;
                Panel host = new() { Dock = DockStyle.Fill, BackColor = back };
                document.Controls.Add(host);
                Type panelType = AppAssembly.GetType("mRemoteNG.UI.Controls.RdpConnectingPanel", true)!;
                object panel = Activator.CreateInstance(panelType, BindingFlags.Instance | BindingFlags.NonPublic, null, new object[] { host, "Connecting..." }, null)!;
                _connectingPreview = (Control)panel;
                panelType.GetMethod("ApplyColors", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(panel, new object[] { back, fore });
                panelType.GetMethod("ShowConnecting", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(panel, null);
                document.Show(dock, DockState.Document);
                form.Activate(); form.BringToFront();
                _stage++;
            }
            else if (_stage == 1)
            {
                Capture(form, "01-main.png");
                MenuStrip menu = form.Controls.Find("msMain", true).OfType<MenuStrip>().First();
                _captureMenu = ((ToolStripMenuItem)menu.Items[0]).DropDown;
                _captureMenu.Closing += (_, closing) =>
                {
                    Console.WriteLine($"File menu closing: {closing.CloseReason}; capture pending: {_holdingMenuForCapture}");
                    // The runner's desktop can change activation between timer ticks.
                    // Hold this real popup only while its screenshot is pending.
                    if (_holdingMenuForCapture) closing.Cancel = true;
                };
                _holdingMenuForCapture = true;
                _captureMenu.AutoClose = false;
                Console.WriteLine("Opening File menu");
                ((ToolStripMenuItem)menu.Items[0]).ShowDropDown();
                Console.WriteLine($"File menu opened; visible: {_captureMenu.Visible}; bounds: {_captureMenu.Bounds}");
                _stage++;
            }
            else if (_stage == 2)
            {
                if (_captureMenu == null || !_captureMenu.Visible)
                    throw new InvalidOperationException("The File menu is missing from the menu capture.");
                _captureMenu.Refresh();
                Capture(form, "02-file-menu.png");
                _holdingMenuForCapture = false;
                _captureMenu.Close();
                _captureMenu.AutoClose = true;
                ConnectionTreeWindow tree = (ConnectionTreeWindow)Window("TreeForm"); tree.Activate(); tree.ConnectionTree.Focus();
                _stage++;
            }
            else
            {
                ConnectionTreeWindow tree = (ConnectionTreeWindow)Window("TreeForm");
                if (!tree.Visible || !tree.ConnectionTree.Visible)
                    throw new InvalidOperationException("The connection tree is missing from the focused-tree capture.");
                tree.Activate(); tree.ConnectionTree.Focus();
                Capture(form, "03-tree-focus.png");
                ThemeManager manager = ThemeManager.getInstance();
                File.WriteAllText(Path.Combine(_output, "scope.txt"), $"Real mRemoteNG main window, native menus/tree/config and actual connecting-panel source. Theme: {manager.ActiveTheme.Name}; enabled: {manager.ThemingActive}. Tree guide ARGB: {tree.ConnectionTree.TreeColumnRenderer.LinePen.Color.ToArgb():X8}. Synthetic records with empty hostnames; no RDP connection or authentication was attempted. Native RDP layering and live remote logon remain untested. DPI: {form.DeviceDpi}.\n");
                _finished = true; timer.Stop(); ExitFixture(0);
            }
        }
        catch (Exception error)
        {
            _failure = error;
            Console.Error.WriteLine(error);
            File.WriteAllText(Path.Combine(_output, "preview-error.txt"), error.ToString());
            ExitFixture(1);
        }
        finally
        {
            _ticking = false;
            if (!_finished && _failure == null) timer.Start();
        }
    }

    private static void ExitFixture(int exitCode)
    {
        // This process only runs in a disposable, guarded portable fixture.
        // App shutdown can prompt about synthetic unsaved records and hang CI.
        // Evidence is already written synchronously; retain the real result code.
        Console.Out.Flush();
        Console.Error.Flush();
        Environment.Exit(exitCode);
    }

    private static void Capture(Form form, string name)
    {
        ThemeManager manager = ThemeManager.getInstance();
        if (manager.ThemingActive != !_disabled || manager.ActiveTheme.UseFluentIcons != (!_disabled && _theme == "Catppuccin Mocha Comfortable"))
            throw new InvalidOperationException("The actual theme state does not match the requested capture mode.");
        // The ordinary UI loop has already painted between stages. Pumping
        // another message loop here can re-enter timer/menu processing.
        form.Refresh();
        using Bitmap image = new(form.Width, form.Height);
        using (Graphics graphics = Graphics.FromImage(image)) graphics.CopyFromScreen(form.Location, Point.Empty, form.Size);
        Control preview = _connectingPreview ?? throw new InvalidOperationException("Connecting preview is missing.");
        Point sample = preview.PointToScreen(new Point(preview.Width / 2, preview.Height / 3));
        sample.Offset(-form.Left, -form.Top);
        if (!preview.Visible || !new Rectangle(Point.Empty, image.Size).Contains(sample))
            throw new InvalidOperationException("Connecting preview is not visible in the captured window.");
        Color actual = image.GetPixel(sample.X, sample.Y), expected = preview.BackColor;
        if (Math.Abs(actual.R - expected.R) > 3 || Math.Abs(actual.G - expected.G) > 3 || Math.Abs(actual.B - expected.B) > 3)
            throw new InvalidOperationException($"Desktop capture does not show the expected app surface: {actual} versus {expected}. Check for an occluded or locked desktop.");
        image.Save(Path.Combine(_output, name), ImageFormat.Png);
        Console.WriteLine($"Captured {name}");
    }
}
