// Forest Studio 2.0 / v0.4 — WPF shell for Autodesk 3ds Max 2024 (.NET Framework)
// UI only. Never edits Max scene directly. All scene operations go through MAXScript events.
using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace ForestStudio.UI
{
    public class StudioActionEventArgs : EventArgs
    {
        public string Command { get; private set; }
        public string Value { get; private set; }
        public StudioActionEventArgs(string command, string value) { Command = command; Value = value; }
    }

    public class GroupView
    {
        public string Name, Rgb;
        public double Density, MinScale, MaxScale, Inside, Tilt;
        public bool Rotation, Align;
        public List<string> Refs = new List<string>();
        public List<double> Weights = new List<double>();
    }

    public class StudioWindow : Window
    {
        public event EventHandler<StudioActionEventArgs> ActionRequested;
        private readonly Color bg = Color.FromRgb(20, 26, 30);
        private readonly Color surface = Color.FromRgb(29, 37, 42);
        private readonly Color panel = Color.FromRgb(36, 46, 50);
        private readonly Color accent = Color.FromRgb(123, 173, 130);
        private readonly Color foreground = Color.FromRgb(223, 232, 227);
        private readonly Color muted = Color.FromRgb(149, 167, 163);
        private readonly List<string> assets = new List<string>();
        private readonly List<GroupView> groups = new List<GroupView>();
        private readonly HashSet<string> selectedAssets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, BitmapImage> thumbnailCache = new Dictionary<string, BitmapImage>(StringComparer.OrdinalIgnoreCase);
        private readonly List<Button> navButtons = new List<Button>();
        private string thumbnailDirectory = "";
        private Grid mainContent;
        private readonly UIElement[] pageCache = new UIElement[5];
        private TextBlock statusLabel, selectedLabel, groupCountLabel, maskSummary, maskNameLabel;
        private TextBox terrain, mask, scale, seed, sdk, partProject;
        private CheckBox subobject;
        private TextBox presetName;
        private ComboBox presetChoice;
        private readonly List<string> presetNameCache = new List<string>();
        private TextBox search;
        private ComboBox category, libraryGroup;
        private WrapPanel assetWrap;
        private Image maskImage;
        private BitmapSource maskBitmap, alphaMaskBitmap;
        private CheckBox showMaskAlpha;
        private byte[] maskPixels;
        private int maskWidth, maskHeight;
        private string currentMaskFile = "";
        private DateTime currentMaskStamp = DateTime.MinValue;
        private readonly DispatcherTimer groupAutoTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(650) };
        private readonly DispatcherTimer projectAutoTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1000) };
        private ListBox placementGroups, groupMembers, libraryMembers;
        private TextBox groupName, groupRgb, groupDensity, groupMin, groupMax, groupInside, groupTilt;
        private Border groupColorSwatch;
        private CheckBox groupRotation, groupAlign;
        private TextBox exportPrefix;
        private TextBlock exportPartInfo;
        private CheckBox exportSelected;
        private TextBlock exportStats, projectSummary, librarySummary;
        private int activeTab = 0;
        private int currentGroup = -1;
        private bool populating = false;

        public StudioWindow()
        {
            Title = "Forest Studio 2.0 · X-Ray SDK";
            Width = 1350; Height = 870; MinWidth = 1060; MinHeight = 690;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            FontFamily = new FontFamily("Segoe UI"); FontSize = 13;
            Background = Brush(bg); Foreground = Brush(foreground);
            groupAutoTimer.Tick += (s, e) => { groupAutoTimer.Stop(); CaptureGroupView(); Send("GroupAutoSave", ""); };
            projectAutoTimer.Tick += (s, e) => { projectAutoTimer.Stop(); Send("ProjectAutoSave", ""); };
            BuildShell(); ShowPage(0);
            TryEnableModelessKeyboardInterop();
            // MAXScript bridge temporarily disables 3ds Max shortcuts while this
            // modeless WPF window has focus; all accelerators are restored on leave.
            Activated += (s, e) => Send("WindowActivated", "");
            Deactivated += (s, e) => Send("WindowDeactivated", "");
            Closed += (s, e) => { FlushGroupChanges(); FlushProjectChanges(); Send("Closed", ""); };
        }

        // Optional WinForms message filter for modeless WPF hosted in 3ds Max.
        // Loaded by reflection so the working v0.4.2 build script needs no extra
        // WindowsFormsIntegration reference. MAXScript also toggles accelerators.
        private void TryEnableModelessKeyboardInterop()
        {
            try
            {
                var assembly = System.Reflection.Assembly.Load("WindowsFormsIntegration");
                var hostType = assembly.GetType("System.Windows.Forms.Integration.ElementHost", false);
                if (hostType == null) return;
                var method = hostType.GetMethod("EnableModelessKeyboardInterop", new Type[] { typeof(Window) });
                if (method != null) method.Invoke(null, new object[] { this });
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine("Forest Studio: WPF keyboard interop unavailable: " + ex.Message);
            }
        }

        private SolidColorBrush Brush(Color c) { return new SolidColorBrush(c); }
        private Thickness Pad(double all) { return new Thickness(all); }
        private Border Box(UIElement child, Color color, double padding, double corner)
        {
            return new Border { Background = Brush(color), Padding = Pad(padding), CornerRadius = new CornerRadius(corner), Child = child };
        }
        private TextBlock Text(string value, int size, bool bold, Color color)
        {
            return new TextBlock { Text = value, FontSize = size, Foreground = Brush(color), FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        }
        private Button Button(string title, bool primary, Action click)
        {
            Button b = new Button { Content = title, Margin = new Thickness(0, 0, 8, 8), Padding = new Thickness(17, 9, 17, 9), BorderThickness = new Thickness(0), Cursor = Cursors.Hand, Foreground = Brush(primary ? bg : foreground), Background = Brush(primary ? accent : panel), FontWeight = FontWeights.SemiBold, MinHeight = 35 };
            b.Click += (s, e) => { if (click != null) click(); };
            return b;
        }
        private TextBox Input(string initial)
        {
            return new TextBox { Text = initial, Background = Brush(panel), Foreground = Brush(foreground), CaretBrush = Brush(foreground), BorderBrush = Brush(Color.FromRgb(62, 75, 77)), BorderThickness = new Thickness(1), Padding = Pad(8), MinHeight = 31, VerticalContentAlignment = VerticalAlignment.Center };
        }
        private CheckBox Check(string label)
        {
            return new CheckBox { Content = label, Foreground = Brush(foreground), Margin = new Thickness(2, 8, 12, 10), VerticalAlignment = VerticalAlignment.Center };
        }
        private ComboBox Combo()
        {
            return new ComboBox { Margin = new Thickness(0, 4, 8, 8), Height = 34, Background = Brush(panel), Foreground = Brushes.Black, Padding = new Thickness(8, 4, 8, 4) };
        }
        private StackPanel Stack(bool horizontal)
        {
            return new StackPanel { Orientation = horizontal ? Orientation.Horizontal : Orientation.Vertical };
        }
        private void Label(StackPanel s, string label) { s.Children.Add(new TextBlock { Text = label, Foreground = Brush(muted), Margin = new Thickness(0, 8, 0, 4) }); }
        private Border Section(string title, UIElement contents)
        {
            StackPanel panelStack = Stack(false);
            panelStack.Children.Add(new TextBlock { Text = title.ToUpperInvariant(), Foreground = Brush(muted), FontSize = 11, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 0, 12) });
            panelStack.Children.Add(contents);
            Border p = Box(panelStack, surface, 18, 9);
            p.Margin = new Thickness(0, 0, 12, 14);
            return p;
        }
        private Grid GridCols(params double[] widths)
        {
            Grid grid = new Grid();
            foreach (double w in widths) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(w, GridUnitType.Star) });
            return grid;
        }
        private void Col(Grid g, UIElement child, int col) { Grid.SetColumn(child, col); g.Children.Add(child); }
        private void Send(string command, string value)
        {
            EventHandler<StudioActionEventArgs> handler = ActionRequested;
            if (handler != null)
            {
                try { handler(this, new StudioActionEventArgs(command, value ?? "")); }
                catch (Exception ex) { Notify("Ошибка команды " + command + ":\n" + ex.Message, "Forest Studio"); }
            }
        }
        // Dialogs MUST have Forest Studio as their owner; 3ds Max is not the owner.
        public void Notify(string message, string title)
        {
            System.Windows.MessageBox.Show(this, message ?? "", title ?? "Forest Studio", MessageBoxButton.OK, MessageBoxImage.Information);
            RestoreStudioFocus();
        }
        public bool Confirm(string message, string title)
        {
            bool yes = System.Windows.MessageBox.Show(this, message ?? "", title ?? "Forest Studio", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;
            RestoreStudioFocus();
            return yes;
        }
        public string ChooseFile(string description, string filter, string initialPath)
        {
            var dialog = new Microsoft.Win32.OpenFileDialog();
            dialog.Title = description ?? "Выбрать файл";
            dialog.Filter = string.IsNullOrWhiteSpace(filter) ? "Все файлы|*.*" : filter.TrimEnd('|');
            if (!string.IsNullOrWhiteSpace(initialPath))
            {
                try
                {
                    string dir = System.IO.Directory.Exists(initialPath) ? initialPath : System.IO.Path.GetDirectoryName(initialPath);
                    if (System.IO.Directory.Exists(dir)) dialog.InitialDirectory = dir;
                }
                catch { }
            }
            bool? ok = dialog.ShowDialog(this);
            RestoreStudioFocus();
            return ok == true ? dialog.FileName : "";
        }
        private class DialogOwner : System.Windows.Forms.IWin32Window
        {
            public IntPtr Handle { get; private set; }
            public DialogOwner(IntPtr handle) { Handle = handle; }
        }
        public string ChooseSdkFolder(string initialPath)
        {
            using (var dlg = new System.Windows.Forms.FolderBrowserDialog())
            {
                dlg.Description = "Выбери корневую папку X-Ray SDK (с rawdata и gamedata)";
                dlg.ShowNewFolderButton = false;
                if (System.IO.Directory.Exists(initialPath)) dlg.SelectedPath = initialPath;
                var win = new System.Windows.Interop.WindowInteropHelper(this);
                var result = dlg.ShowDialog(new DialogOwner(win.Handle));
                RestoreStudioFocus();
                return result == System.Windows.Forms.DialogResult.OK ? dlg.SelectedPath : "";
            }
        }
        public void RestoreStudioFocus()
        {
            try
            {
                if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
                if (!IsActive) Activate();
            }
            catch { }
        }

        private void BuildShell()
        {
            Grid root = new Grid();
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(212) });
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(36) });
            Content = root;
            StackPanel side = Stack(false); side.Margin = new Thickness(16, 25, 16, 0);
            side.Children.Add(Text("FOREST", 24, true, foreground));
            side.Children.Add(Text("STUDIO  /  X-RAY SDK", 10, true, accent));
            side.Children.Add(new Border { Height = 1, Background = Brush(panel), Margin = new Thickness(0, 26, 0, 20) });
            string[] names = { "Проект", "Библиотека", "Маска", "Расстановка", "Экспорт SDK" };
            string[] icons = { "◈", "▦", "◉", "♣", "⇧" };
            for (int i = 0; i < names.Length; i++)
            {
                int index = i;
                Button nav = Button(icons[i] + "    " + names[i], false, () => ShowPage(index));
                nav.HorizontalContentAlignment = HorizontalAlignment.Left;
                nav.Margin = new Thickness(0, 0, 0, 8); nav.Height = 48;
                navButtons.Add(nav); side.Children.Add(nav);
            }
            side.Children.Add(new Border { Height = 1, Background = Brush(panel), Margin = new Thickness(0, 35, 0, 12) });
            side.Children.Add(Text("Forest Studio v0.4.6", 12, true, foreground));
            side.Children.Add(Text("WPF UI · MAXScript backend", 11, false, muted));
            Border sidebar = Box(side, surface, 0, 0);
            Grid.SetColumn(sidebar, 0); root.Children.Add(sidebar);
            Grid content = new Grid(); content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(84) });
            content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            StackPanel hdr = Stack(false); hdr.Margin = new Thickness(26, 12, 24, 0);
            hdr.Children.Add(Text("ENVIRONMENT EDITOR", 23, true, foreground));
            hdr.Children.Add(Text("Объекты X-Ray · Маски · LOD · Экспорт .part", 12, false, muted));
            Grid.SetRow(hdr, 0); content.Children.Add(hdr);
            mainContent = new Grid { Margin = new Thickness(20, 0, 10, 8) };
            Grid.SetRow(mainContent, 1); content.Children.Add(mainContent);
            Grid.SetColumn(content, 1); root.Children.Add(content);
            statusLabel = Text("Готово к работе", 11, false, muted); statusLabel.Margin = new Thickness(18, 0, 0, 0);
            Border status = Box(statusLabel, surface, 5, 0);
            Grid.SetRow(status, 1); Grid.SetColumnSpan(status, 2); root.Children.Add(status);
        }
        private void ShowPage(int index)
        {
            if (activeTab == 3 && index != 3) FlushGroupChanges();
            if (activeTab == 0 && index != 0) FlushProjectChanges();
            activeTab = index; mainContent.Children.Clear();
            for (int i = 0; i < navButtons.Count; i++)
            {
                navButtons[i].Background = Brush(i == index ? accent : panel);
                navButtons[i].Foreground = Brush(i == index ? bg : foreground);
            }
            // Cache WPF pages: returning to a tab must not silently reset unsaved text.
            if (pageCache[index] == null)
            {
                if (index == 0) pageCache[index] = ProjectPage();
                if (index == 1) pageCache[index] = LibraryPage();
                if (index == 2) pageCache[index] = MaskPage();
                if (index == 3) pageCache[index] = PlacementPage();
                if (index == 4) pageCache[index] = ExportPage();
            }
            mainContent.Children.Add(pageCache[index]);
        }
        private ScrollViewer Scroll(UIElement child)
        {
            return new ScrollViewer { Content = child, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Padding = new Thickness(0, 0, 0, 10) };
        }
        private UIElement ProjectPage()
        {
            StackPanel all = Stack(false);
            all.Children.Add(Text("Проект и источники", 22, true, foreground));
            all.Children.Add(new Border { Height = 16 });
            StackPanel terrainSection = Stack(false);
            Label(terrainSection, "Террейн в сцене 3ds Max"); terrain = Input(""); terrain.IsReadOnly = true; terrainSection.Children.Add(terrain);
            StackPanel buttons = Stack(true); buttons.Margin = new Thickness(0, 12, 0, 0);
            buttons.Children.Add(Button("Взять выделенный террейн", true, () => Send("TerrainSelection", "")));
            terrainSection.Children.Add(buttons);
            Label(terrainSection, "RGB / Alpha маска"); mask = Input(""); mask.IsReadOnly = true; terrainSection.Children.Add(mask);
            terrainSection.Children.Add(Button("Выбрать *_forest.tga", false, () => Send("MaskBrowse", "")));
            projectSummary = Text("RGB задаёт группу, Alpha — вероятность посадки", 12, false, muted); terrainSection.Children.Add(projectSummary);
            all.Children.Add(Section("Местность", terrainSection));
            Grid settings = GridCols(1, 1, 2); settings.Margin = new Thickness(0, 0, 0, 8);
            StackPanel s1 = Stack(false); Label(s1, "1 игровой метр = units"); scale = Input("1.0"); s1.Children.Add(scale);
            StackPanel s2 = Stack(false); Label(s2, "Seed"); seed = Input("1"); s2.Children.Add(seed);
            scale.TextChanged += (s,e) => ScheduleProjectSave();
            seed.TextChanged += (s,e) => ScheduleProjectSave();
            subobject = Check("Только выделенные полигоны террейна");
            subobject.Checked += (s,e) => ScheduleProjectSave();
            subobject.Unchecked += (s,e) => ScheduleProjectSave();
            Col(settings, s1, 0); Col(settings, s2, 1); Col(settings, subobject, 2);
            all.Children.Add(Section("Настройки генерации", settings));
            StackPanel paths = Stack(false);
            Label(paths, "Корень X-Ray SDK (папка, содержащая rawdata и gamedata)"); sdk = Input("");
            sdk.LostKeyboardFocus += (s,e) => ScheduleProjectSave(); paths.Children.Add(sdk);
            paths.Children.Add(Button("Выбрать SDK", false, () => Send("BrowseSDK", "")));
            paths.Children.Add(Text("Объекты: <SDK>\\rawdata\\objects  ·  Текстуры: <SDK>\\gamedata\\textures", 12, false, muted));
            Label(paths, "scene_object.part"); partProject = Input("");
            partProject.LostKeyboardFocus += (s,e) => ScheduleProjectSave(); paths.Children.Add(partProject);
            paths.Children.Add(Button("Выбрать .part", false, () => Send("BrowsePart", "")));
            all.Children.Add(Section("Пути SDK", paths));
            all.Children.Add(Text("Изменения проекта сохраняются автоматически. Пресеты групп теперь находятся на вкладке «Расстановка».", 12, false, muted));
            return Scroll(all);
        }
        private UIElement LibraryPage()
        {
            Grid layout = GridCols(3.2, 1.15);
            librarySummary = Text("Все .object из SDK\\rawdata\\objects\\trees (включая вложенные папки)", 12, false, muted); librarySummary.Margin = new Thickness(0, 4, 0, 12);
            StackPanel filters = Stack(true);
            search = Input(""); search.MinWidth = 260; search.Margin = new Thickness(0, 0, 8, 10);
            search.TextChanged += (s, e) => RefreshAssetCards(); filters.Children.Add(search);
            category = Combo(); category.Width = 190;
            category.Items.Add("Все папки");
            category.SelectedIndex = 0; category.SelectionChanged += (s, e) => RefreshAssetCards(); filters.Children.Add(category);
            RefreshFolders();
            assetWrap = new WrapPanel { Orientation = Orientation.Horizontal };
            ScrollViewer thumbs = Scroll(assetWrap); thumbs.Background = Brush(surface);
            // fixed-height flexible grid through nested grid instead of StackPanel (prevents endless ScrollViewer size)
            Grid lefthost = new Grid(); lefthost.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            lefthost.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            StackPanel top = Stack(false);
            top.Children.Add(Text("Библиотека X-Ray", 22, true, foreground));
            top.Children.Add(librarySummary); top.Children.Add(filters);
            Grid.SetRow(top, 0); lefthost.Children.Add(top);
            Grid.SetRow(thumbs, 1); lefthost.Children.Add(thumbs);
            Col(layout, lefthost, 0);
            StackPanel right = Stack(false);
            right.Children.Add(Text("Выбранные модели", 18, true, foreground));
            selectedLabel = Text("0 выбрано", 12, false, muted); selectedLabel.Margin = new Thickness(0, 8, 0, 22); right.Children.Add(selectedLabel);
            Label(right, "Добавить в группу"); libraryGroup = Combo(); right.Children.Add(libraryGroup);
            libraryGroup.SelectionChanged += (s, e) => { if (!populating) RefreshMembers(); };
            right.Children.Add(Button("+ Добавить выбранные", true, () => Send("GroupAddAssets", "")));
            Label(right, "Состав группы"); libraryMembers = new ListBox { Height = 240, Background = Brush(panel), Foreground = Brush(foreground), BorderThickness = new Thickness(0) }; right.Children.Add(libraryMembers);
            right.Children.Add(Button("Убрать из группы", false, () => Send("GroupRemoveAsset", "")));
            right.Children.Add(new Border { Height = 20 });
            right.Children.Add(Button("Подготовить LOD выбранных", false, () => Send("PrepareSelected", "")));
            right.Children.Add(Button("THM → PNG (Flip Y)", false, () => Send("BuildThumbnails", "")));
            right.Children.Add(Button("Очистить кэш иконок", false, () => Send("ClearThumbnails", "")));
            right.Children.Add(Text("Очистка удаляет только PNG каталога и его служебные файлы. Оригиналы THM не затрагиваются.", 11, false, muted));
            Border side = Section("Менеджер источников", right); side.Margin = new Thickness(16, 0, 0, 0);
            Col(layout, side, 1);
            RefreshLibraryGroupControls(); RefreshAssetCards();
            return layout;
        }
        private BitmapImage GetThumb(string reference)
        {
            if (string.IsNullOrEmpty(thumbnailDirectory)) return null;
            BitmapImage found;
            if (thumbnailCache.TryGetValue(reference, out found)) return found;
            string name = reference.Replace('\\', '_').Replace('/', '_') + ".png";
            string path = System.IO.Path.Combine(thumbnailDirectory, name);
            if (!File.Exists(path)) return null;
            try
            {
                BitmapImage image = new BitmapImage(); image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad;
                image.DecodePixelWidth = 128; image.UriSource = new Uri(path, UriKind.Absolute); image.EndInit(); image.Freeze();
                thumbnailCache[reference] = image; return image;
            }
            catch { return null; }
        }
        private string AssetFolder(string reference)
        {
            // First subdirectory inside rawdata\objects\trees, such as absolute_nature.
            string[] segments = reference.Replace('/', '\\').Split('\\');
            if (segments.Length < 3) return "(корень trees)";
            return segments[0].Equals("trees", StringComparison.OrdinalIgnoreCase) ? segments[1] : segments[0];
        }
        private void RefreshFolders()
        {
            if (category == null) return;
            string previous = category.SelectedItem == null ? "Все папки" : category.SelectedItem.ToString();
            var folders = assets.Select(AssetFolder).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(s => s, StringComparer.OrdinalIgnoreCase).ToList();
            category.Items.Clear(); category.Items.Add("Все папки");
            foreach (string folder in folders) category.Items.Add(folder);
            category.SelectedItem = folders.FirstOrDefault(f => string.Equals(f, previous, StringComparison.OrdinalIgnoreCase)) ?? "Все папки";
        }
        private void RefreshAssetCards()
        {
            if (assetWrap == null) return;
            assetWrap.Children.Clear();
            string query = search == null ? "" : search.Text.Trim().ToLowerInvariant();
            string cat = category == null || category.SelectedItem == null ? "Все папки" : category.SelectedItem.ToString();
            int shown = 0;
            int rendered = 0;
            const int maxCards = 400; // Search/category filter narrows very large SDK directories.
            foreach (string id in assets)
            {
                if (query.Length > 0 && !id.ToLowerInvariant().Contains(query)) continue;
                if (cat != "Все папки" && AssetFolder(id) != cat) continue;
                shown++;
                if (rendered >= maxCards) continue;
                rendered++;
                bool selected = selectedAssets.Contains(id);
                StackPanel content = Stack(false); content.Width = 125;
                BitmapImage bitmap = GetThumb(id);
                if (bitmap != null)
                {
                    content.Children.Add(new Image { Source = bitmap, Width = 112, Height = 110, Stretch = Stretch.Uniform, Margin = new Thickness(0, 0, 0, 8) });
                }
                else
                {
                    Border p = Box(Text("▧", 36, false, muted), panel, 14, 8);
                    p.Width = 112; p.Height = 110; p.Margin = new Thickness(0, 0, 0, 8);
                    content.Children.Add(p);
                }
                string name = id.Substring(id.LastIndexOf('\\') + 1);
                content.Children.Add(new TextBlock { Text = name, Foreground = Brush(foreground), FontSize = 11, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Height = 36, ToolTip = id });
                Border card = Box(content, selected ? Color.FromRgb(50, 87, 66) : panel, 10, 8);
                card.Margin = new Thickness(5); card.BorderThickness = new Thickness(selected ? 2 : 1); card.BorderBrush = Brush(selected ? accent : surface);
                Button button = new Button { Content = card, Tag = id, BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(0), ToolTip = id, Cursor = Cursors.Hand };
                button.Click += (s, e) =>
                {
                    string key = (string)((Button)s).Tag;
                    bool multi = (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control;
                    if (!multi) selectedAssets.Clear();
                    if (!selectedAssets.Add(key)) selectedAssets.Remove(key);
                    RefreshAssetCards();
                };
                assetWrap.Children.Add(button);
            }
            if (librarySummary != null) librarySummary.Text = shown + " найдено · всего " + assets.Count + (shown > maxCards ? " · показаны первые " + maxCards + " (уточни поиск)" : "");
            if (selectedLabel != null) selectedLabel.Text = selectedAssets.Count + " выбрано (Ctrl — мультивыбор)";
        }
        private void ScheduleGroupSave()
        {
            if (populating || currentGroup < 0 || groupName == null) return;
            groupAutoTimer.Stop(); groupAutoTimer.Start();
        }
        private void ScheduleProjectSave()
        {
            if (populating || sdk == null) return;
            projectAutoTimer.Stop(); projectAutoTimer.Start();
        }
        private void FlushGroupChanges()
        {
            if (groupAutoTimer.IsEnabled)
            {
                groupAutoTimer.Stop(); CaptureGroupView(); Send("GroupAutoSave", "");
            }
        }
        private void FlushProjectChanges()
        {
            if (projectAutoTimer.IsEnabled) { projectAutoTimer.Stop(); Send("ProjectAutoSave", ""); }
        }
        private bool Number(string text, out double value)
        {
            return double.TryParse((text ?? "").Trim().Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out value);
        }
        private void CaptureGroupView()
        {
            if (currentGroup < 0 || currentGroup >= groups.Count || groupName == null) return;
            GroupView g = groups[currentGroup]; double d;
            g.Name = groupName.Text; g.Rgb = groupRgb.Text;
            if (Number(groupDensity.Text, out d)) g.Density = d;
            if (Number(groupMin.Text, out d)) g.MinScale = d;
            if (Number(groupMax.Text, out d)) g.MaxScale = d;
            if (Number(groupInside.Text, out d)) g.Inside = d;
            if (Number(groupTilt.Text, out d)) g.Tilt = d;
            g.Rotation = groupRotation.IsChecked == true; g.Align = groupAlign.IsChecked == true;
            if (placementGroups != null && currentGroup < placementGroups.Items.Count && placementGroups.SelectedIndex == currentGroup)
            {
                populating = true;
                placementGroups.Items[currentGroup] = g.Name + "  ·  " + g.Density.ToString("0", CultureInfo.InvariantCulture) + "/га";
                placementGroups.SelectedIndex = currentGroup;
                populating = false;
            }
        }
        private TextBox ScaleInput(string initial, StackPanel parent)
        {
            StackPanel row = Stack(true);
            TextBox value = Input(initial); value.Width = 85; row.Children.Add(value);
            StackPanel arrows = Stack(false); arrows.Margin = new Thickness(5, 0, 0, 0);
            Action<int> step = direction => {
                double v;
                if (!Number(value.Text, out v)) v = 1.0;
                double next = Math.Max(0.05, Math.Round((v + direction * 0.05) * 20.0, MidpointRounding.AwayFromZero) / 20.0);
                value.Text = next.ToString("0.00", CultureInfo.InvariantCulture);
            };
            Button up = Button("▲", false, () => step(1)); up.Padding = new Thickness(6,0,6,0); up.MinHeight = 15; up.Height = 17; up.Margin = new Thickness(0,0,0,1);
            Button down = Button("▼", false, () => step(-1)); down.Padding = new Thickness(6,0,6,0); down.MinHeight = 15; down.Height = 17; down.Margin = new Thickness(0);
            arrows.Children.Add(up); arrows.Children.Add(down); row.Children.Add(arrows); parent.Children.Add(row);
            return value;
        }

        private TextBox StepInput(string initial, StackPanel parent, double increment, double minimum, double maximum)
        {
            StackPanel row = Stack(true);
            TextBox value = Input(initial); value.Width = 85; row.Children.Add(value);
            StackPanel arrows = Stack(false); arrows.Margin = new Thickness(5, 0, 0, 0);
            Action<int> step = direction => {
                double v;
                if (!Number(value.Text, out v)) v = minimum;
                double next = Math.Max(minimum, Math.Min(maximum, Math.Round(v + direction * increment, 4, MidpointRounding.AwayFromZero)));
                value.Text = next.ToString("0.##", CultureInfo.InvariantCulture);
            };
            Button up = Button("▲", false, () => step(1)); up.Padding = new Thickness(6,0,6,0); up.MinHeight = 15; up.Height = 17; up.Margin = new Thickness(0,0,0,1);
            Button down = Button("▼", false, () => step(-1)); down.Padding = new Thickness(6,0,6,0); down.MinHeight = 15; down.Height = 17; down.Margin = new Thickness(0);
            arrows.Children.Add(up); arrows.Children.Add(down); row.Children.Add(arrows); parent.Children.Add(row);
            return value;
        }

        // Native TGA reader for the exact 24/32-bit mask used by the forest backend.
        // Windows WPF has no built-in TGA codec, so BitmapImage cannot be used here.
        private static BitmapSource DecodeTga(string path, out byte[] pixels, out int w, out int h)
        {
            using (BinaryReader br = new BinaryReader(File.OpenRead(path)))
            {
                byte idLength = br.ReadByte(), colorMapType = br.ReadByte(), imageType = br.ReadByte();
                br.ReadBytes(5); br.ReadUInt16(); br.ReadUInt16();
                w = br.ReadUInt16(); h = br.ReadUInt16();
                byte depth = br.ReadByte(), descriptor = br.ReadByte();
                if (colorMapType != 0 || (imageType != 2 && imageType != 10) || (depth != 24 && depth != 32) || w == 0 || h == 0 || w > 16384 || h > 16384)
                    throw new InvalidDataException("Поддерживаются только TGA truecolor 24/32-bit, тип 2 или 10 (RLE).");
                br.ReadBytes(idLength);
                int bpp = depth / 8, size = checked(w * h);
                pixels = new byte[checked(size * 4)];
                bool top = (descriptor & 0x20) != 0, right = (descriptor & 0x10) != 0;
                bool hasAlpha = (descriptor & 0x0F) != 0 && bpp == 4;
                int index = 0;
                int width = w, height = h;
                byte[] buffer = pixels;
                Action<byte[]> put = px => {
                    int row = index / width, col = index % width;
                    if (!top) row = height - 1 - row;
                    if (right) col = width - 1 - col;
                    int dst = (row * width + col) * 4;
                    buffer[dst] = px[0]; buffer[dst+1] = px[1]; buffer[dst+2] = px[2]; buffer[dst+3] = hasAlpha ? px[3] : (byte)255;
                    index++;
                };
                if (imageType == 2)
                {
                    for (; index < size;) { byte[] px = br.ReadBytes(bpp); if (px.Length != bpp) throw new EndOfStreamException(); put(px); }
                }
                else
                {
                    while (index < size)
                    {
                        byte cmd = br.ReadByte(); int count = (cmd & 0x7F) + 1;
                        if (index + count > size) throw new InvalidDataException("Повреждённая RLE-маска.");
                        if ((cmd & 0x80) != 0)
                        {
                            byte[] px = br.ReadBytes(bpp); if (px.Length != bpp) throw new EndOfStreamException();
                            for (int j = 0; j < count; j++) put(px);
                        }
                        else
                        {
                            for (int j = 0; j < count; j++) { byte[] px = br.ReadBytes(bpp); if (px.Length != bpp) throw new EndOfStreamException(); put(px); }
                        }
                    }
                }
                // Show RGB even in pixels whose alpha is zero; alpha still controls placement in MAXScript.
                BitmapSource result = BitmapSource.Create(w, h, 96, 96, PixelFormats.Bgr32, null, pixels, w * 4);
                result.Freeze(); return result;
            }
        }
        private void SetMaskSource(string path)
        {
            DateTime stamp = File.Exists(path) ? File.GetLastWriteTimeUtc(path) : DateTime.MinValue;
            if (string.Equals(path, currentMaskFile, StringComparison.OrdinalIgnoreCase) && maskBitmap != null && stamp == currentMaskStamp) return;
            currentMaskStamp = stamp;
            currentMaskFile = path ?? ""; maskBitmap = null; alphaMaskBitmap = null; maskPixels = null; maskWidth = maskHeight = 0;
            if (File.Exists(currentMaskFile))
            {
                try
                {
                    if (System.IO.Path.GetExtension(currentMaskFile).Equals(".tga", StringComparison.OrdinalIgnoreCase))
                        maskBitmap = DecodeTga(currentMaskFile, out maskPixels, out maskWidth, out maskHeight);
                    else
                    {
                        var image = new BitmapImage(); image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad;
                        image.UriSource = new Uri(currentMaskFile, UriKind.Absolute); image.EndInit(); image.Freeze();
                        maskBitmap = image; maskWidth = image.PixelWidth; maskHeight = image.PixelHeight;
                        maskPixels = new byte[maskWidth * maskHeight * 4];
                        FormatConvertedBitmap converted = new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0);
                        converted.CopyPixels(maskPixels, maskWidth * 4, 0);
                    }
                }
                catch (Exception ex) { if (maskSummary != null) maskSummary.Text = "Ошибка чтения маски: " + ex.Message; }
            }
            if (maskPixels != null && maskWidth > 0 && maskHeight > 0)
            {
                byte[] grayscale = new byte[maskPixels.Length];
                for (int i = 0; i < maskPixels.Length; i += 4)
                {
                    byte a = maskPixels[i + 3];
                    grayscale[i] = a; grayscale[i + 1] = a; grayscale[i + 2] = a; grayscale[i + 3] = 255;
                }
                alphaMaskBitmap = BitmapSource.Create(maskWidth, maskHeight, 96, 96, PixelFormats.Bgr32, null, grayscale, maskWidth * 4);
                alphaMaskBitmap.Freeze();
            }
            UpdateMaskPreview();
            if (maskNameLabel != null)
            {
                string file = System.IO.Path.GetFileNameWithoutExtension(currentMaskFile);
                string basename = file.EndsWith("_forest", StringComparison.OrdinalIgnoreCase) ? file.Substring(0, file.Length-7) : file;
                maskNameLabel.Text = string.IsNullOrEmpty(basename) ? "Маска не выбрана" :
                    basename + "  — текстура террейна\n" + basename + "_det  — detail-трава\n" + basename + "_mask  — материалы\n" + basename + "_forest.tga  — Forest Studio";
            }
            if (maskSummary != null && maskBitmap != null) maskSummary.Text = maskWidth + " × " + maskHeight + " · RGB = группа, Alpha = интенсивность · " + currentMaskFile;
            else if (maskSummary != null && !File.Exists(currentMaskFile)) maskSummary.Text = "Укажи файл *_forest.tga на вкладке «Проект».";
        }
        private void UpdateMaskPreview()
        {
            if (maskImage != null) maskImage.Source = showMaskAlpha != null && showMaskAlpha.IsChecked == true ? alphaMaskBitmap : maskBitmap;
        }
        private UIElement MaskPage()
        {
            StackPanel all = Stack(false);
            all.Children.Add(Text("Маска леса", 22, true, foreground));
            all.Children.Add(Text("Рабочая маска должна называться <имя текстуры террейна>_forest.tga. Оригиналы _det и _mask не изменяются.", 12, false, muted));
            all.Children.Add(new Border { Height = 12 });
            StackPanel controls = Stack(true);
            controls.Children.Add(Button("Открыть *_forest.tga", true, () => Send("MaskBrowse", "")));
            controls.Children.Add(Button("Найти по текстуре террейна", false, () => Send("MaskFindByTexture", "")));
            controls.Children.Add(Button("Создать группы по цветам…", false, () => DetectMaskColorsAndOffer()));
            all.Children.Add(controls);
            showMaskAlpha = Check("Показать альфа-канал (градации серого)");
            showMaskAlpha.Checked += (s,e) => UpdateMaskPreview();
            showMaskAlpha.Unchecked += (s,e) => UpdateMaskPreview();
            all.Children.Add(showMaskAlpha);
            maskSummary = Text("", 12, false, muted); maskSummary.Margin = new Thickness(0,6,0,8); all.Children.Add(maskSummary);
            maskNameLabel = Text("", 12, false, foreground); all.Children.Add(Section("Соглашение об именах", maskNameLabel));
            Border preview = Box(new Grid(), panel, 10, 5); preview.Margin = new Thickness(0, 12, 12, 0);
            Grid canvas = (Grid)preview.Child;
            canvas.Height = 500;
            maskImage = new Image { Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch };
            canvas.Children.Add(maskImage);
            all.Children.Add(preview);
            all.Children.Add(Text("Для выбора цвета группы нажми «Пипетка…» на вкладке «Расстановка». Откроется эта же маска с выбором RGB.", 12, false, muted));
            string loadPath = currentMaskFile; currentMaskFile = ""; SetMaskSource(loadPath);
            return Scroll(all);
        }
        private sealed class MaskColorBin
        {
            public int Key, Count, ModeColor, ModeCount;
            public Dictionary<int, int> Exact = new Dictionary<int, int>();
        }
        private sealed class MaskColorRegion
        {
            public int R, G, B, Count;
            public double Share;
            public CheckBox Selected;
        }
        private static int ColorDistanceSquared(int r, int g, int b, MaskColorRegion c)
        {
            int dr = r - c.R, dg = g - c.G, db = b - c.B;
            return dr * dr + dg * dg + db * db;
        }
        private List<MaskColorRegion> DetectMaskRegions(double tolerance, double minimumFraction)
        {
            var regions = new List<MaskColorRegion>();
            if (maskPixels == null || maskWidth < 1 || maskHeight < 1) return regions;
            // Sampling stride limits both memory and CPU even for very large TGA files.
            int stride = Math.Max(1, (int)Math.Ceiling((double)maskWidth * maskHeight / 240000.0));
            Dictionary<int, MaskColorBin> bins = new Dictionary<int, MaskColorBin>();
            int sampled = 0;
            for (int p = 0; p < maskWidth * maskHeight; p += stride)
            {
                int index = p * 4;
                if (maskPixels[index + 3] < 32) continue; // Ignore near transparent region.
                int r = maskPixels[index + 2], g = maskPixels[index + 1], b = maskPixels[index];
                int key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
                MaskColorBin bin;
                if (!bins.TryGetValue(key, out bin)) { bin = new MaskColorBin { Key = key }; bins.Add(key, bin); }
                bin.Count++; sampled++;
                int exact = (r << 16) | (g << 8) | b, n;
                bin.Exact.TryGetValue(exact, out n); n++;
                bin.Exact[exact] = n;
                if (n > bin.ModeCount) { bin.ModeCount = n; bin.ModeColor = exact; }
            }
            if (sampled == 0) return regions;
            int toleranceSquared = (int)(tolerance * tolerance);
            int minCount = Math.Max(5, (int)Math.Ceiling(sampled * minimumFraction));
            // Dominant 4-bit RGB bins first; blend close shades into a parent cluster.
            foreach (MaskColorBin bin in bins.Values.OrderByDescending(x => x.Count))
            {
                if (bin.Count < minCount / 5) continue;
                int c = bin.ModeColor, r = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255;
                MaskColorRegion near = null;
                foreach (MaskColorRegion existing in regions)
                    if (ColorDistanceSquared(r, g, b, existing) <= toleranceSquared) { near = existing; break; }
                if (near == null)
                {
                    near = new MaskColorRegion { R = r, G = g, B = b };
                    regions.Add(near);
                }
                near.Count += bin.Count;
            }
            foreach (MaskColorRegion region in regions) region.Share = 100.0 * region.Count / sampled;
            return regions.Where(x => x.Count >= minCount).OrderByDescending(x => x.Count).Take(32).ToList();
        }
        private void DetectMaskColorsAndOffer()
        {
            if (maskPixels == null) { Notify("Открой *_forest.tga для поиска цветов.", "Forest Studio"); return; }
            Window dialog = new Window {
                Title = "Группы по цветам лесной маски", Width = 565, Height = 675,
                Owner = this, WindowStartupLocation = WindowStartupLocation.CenterOwner,
                Background = Brush(bg), Foreground = Brush(foreground), FontFamily = FontFamily
            };
            dialog.Activated += (s, e) => Send("WindowActivated", "");
            dialog.Deactivated += (s, e) => Send("WindowDeactivated", "");
            DockPanel root = new DockPanel { Margin = new Thickness(18) };
            dialog.Content = root;
            StackPanel header = Stack(false);
            header.Children.Add(Text("Автопоиск цветов маски", 21, true, foreground));
            header.Children.Add(Text("Близкие RGB-оттенки объединяются, почти прозрачные пиксели и редкий шум игнорируются. Проверь список перед созданием групп (до 32 цветов за раз).", 12, false, muted));
            StackPanel options = Stack(true); options.Margin = new Thickness(0, 12, 0, 8);
            options.Children.Add(Text("Допуск RGB", 12, false, muted));
            TextBox toleranceBox = Input("40"); toleranceBox.Width = 55; toleranceBox.Margin = new Thickness(6, 0, 15, 0); options.Children.Add(toleranceBox);
            options.Children.Add(Text("Мин. площадь, %", 12, false, muted));
            TextBox areaBox = Input("0.5"); areaBox.Width = 65; areaBox.Margin = new Thickness(6, 0, 0, 0); options.Children.Add(areaBox);
            header.Children.Add(options);
            DockPanel.SetDock(header, Dock.Top); root.Children.Add(header);
            StackPanel footer = Stack(true); DockPanel.SetDock(footer, Dock.Bottom); root.Children.Add(footer);
            StackPanel choices = Stack(false);
            ScrollViewer scroller = new ScrollViewer { Content = choices, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            root.Children.Add(scroller);
            List<MaskColorRegion> found = new List<MaskColorRegion>();
            Action refresh = () => {
                double t, a;
                if (!Number(toleranceBox.Text, out t)) t = 40;
                if (!Number(areaBox.Text, out a)) a = 0.5;
                t = Math.Max(0, Math.Min(150, t)); a = Math.Max(0.05, Math.Min(15, a));
                found = DetectMaskRegions(t, a / 100.0);
                choices.Children.Clear();
                if (found.Count == 0) choices.Children.Add(Text("Значимые цвета не найдены. Измени допуск или площадь.", 13, false, muted));
                foreach (MaskColorRegion c in found)
                {
                    StackPanel row = Stack(true); row.Margin = new Thickness(0, 2, 0, 2);
                    CheckBox check = Check(""); check.IsChecked = true; c.Selected = check; row.Children.Add(check);
                    Border colorSample = Box(Text("", 11, false, muted), Color.FromRgb((byte)c.R, (byte)c.G, (byte)c.B), 5, 4);
                    colorSample.Width = 45; colorSample.Height = 30; row.Children.Add(colorSample);
                    row.Children.Add(Text("  " + c.R + "," + c.G + "," + c.B + "    ·    " + c.Share.ToString("0.00", CultureInfo.InvariantCulture) + "%", 13, false, foreground));
                    choices.Children.Add(row);
                }
            };
            footer.Children.Add(Button("Пересчитать", false, () => refresh()));
            footer.Children.Add(Button("Создать выбранные группы", true, () => {
                string payload = string.Join(";", found.Where(c => c.Selected != null && c.Selected.IsChecked == true).Select(c => c.R + "," + c.G + "," + c.B).ToArray());
                if (string.IsNullOrEmpty(payload)) { Notify("Не выбраны цвета для создания групп.", "Forest Studio"); return; }
                Send("MaskCreateGroups", payload); dialog.DialogResult = true;
            }));
            footer.Children.Add(Button("Отмена", false, () => dialog.DialogResult = false));
            refresh(); dialog.ShowDialog(); RestoreStudioFocus();
        }

        private static bool TrySampleImage(Image image, byte[] pixels, int width, int height, System.Windows.Point point, out System.Windows.Media.Color sampled)
        {
            sampled = System.Windows.Media.Colors.Black;
            if (image == null || pixels == null || width <= 0 || height <= 0 || image.ActualWidth <= 0 || image.ActualHeight <= 0) return false;
            double fit = Math.Min(image.ActualWidth / width, image.ActualHeight / height);
            double actualW = fit * width, actualH = fit * height;
            double x = point.X - (image.ActualWidth - actualW) / 2.0;
            double y = point.Y - (image.ActualHeight - actualH) / 2.0;
            if (x < 0 || y < 0 || x >= actualW || y >= actualH) return false;
            int px = Math.Min(width-1, (int)(x / fit)), py = Math.Min(height-1, (int)(y / fit));
            int off = (py * width + px) * 4;
            sampled = Color.FromRgb(pixels[off+2], pixels[off+1], pixels[off]);
            return true;
        }
        private void PickGroupColorFromMask()
        {
            if (currentGroup < 0 || currentGroup >= groups.Count) { Notify("Сначала выбери группу.", "Пипетка"); return; }
            Window dialog = new Window { Title = "Пипетка · Forest Studio", Owner = this, Width = 880, Height = 740,
                WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Brush(bg), Foreground = Brush(foreground) };
            // During owned modal dialogs the main window deactivates. Keep 3ds Max
            // accelerators disabled while the picker itself has keyboard focus.
            dialog.Activated += (s,e) => Send("WindowActivated", "");
            dialog.Deactivated += (s,e) => Send("WindowDeactivated", "");
            Grid layout = new Grid { Margin = new Thickness(18) };
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            StackPanel header = Stack(false);
            header.Children.Add(Text("Нажми на пиксель маски, чтобы взять RGB цвет группы", 17, true, foreground));
            header.Children.Add(Text("Можно выбрать цвет вручную через стандартную палитру Windows.", 12, false, muted));
            Grid.SetRow(header, 0); layout.Children.Add(header);
            Border imageBox = Box(new Grid(), panel, 8, 8); imageBox.Margin = new Thickness(0, 16, 0, 10);
            Image pickerImage = new Image { Source = maskBitmap, Stretch = Stretch.Uniform };
            ((Grid)imageBox.Child).Children.Add(pickerImage);
            pickerImage.Cursor = Cursors.Cross;
            System.Windows.Media.Color chosen = System.Windows.Media.Colors.Red;
            string[] rgb = groupRgb.Text.Split(',');
            int ir, ig, ib;
            if (rgb.Length==3 && int.TryParse(rgb[0],out ir) && int.TryParse(rgb[1],out ig) && int.TryParse(rgb[2],out ib))
                chosen = Color.FromRgb((byte)Math.Max(0,Math.Min(255,ir)), (byte)Math.Max(0,Math.Min(255,ig)), (byte)Math.Max(0,Math.Min(255,ib)));
            Border swatch = Box(Text("", 11, false, muted), chosen, 10, 5); swatch.Width=55; swatch.Height=36;
            TextBlock sampleText = Text("RGB: " + chosen.R + "," + chosen.G + "," + chosen.B, 13, true, foreground);
            Action<System.Windows.Media.Color> showChoice = c => { chosen = c; swatch.Background = Brush(c); sampleText.Text = "RGB: " + c.R + "," + c.G + "," + c.B; };
            pickerImage.MouseLeftButtonDown += (s,e) => {
                System.Windows.Media.Color picked;
                if (TrySampleImage(pickerImage, maskPixels, maskWidth, maskHeight, e.GetPosition(pickerImage), out picked)) showChoice(picked);
            };
            Grid.SetRow(imageBox, 1); layout.Children.Add(imageBox);
            StackPanel bottom = Stack(true); bottom.Margin = new Thickness(0, 12, 0, 0);
            bottom.Children.Add(swatch); bottom.Children.Add(sampleText);
            bottom.Children.Add(Button("Классический выбор…", false, () => {
                using (var colorDlg = new System.Windows.Forms.ColorDialog())
                {
                    colorDlg.FullOpen=true; colorDlg.Color = System.Drawing.Color.FromArgb(chosen.R, chosen.G, chosen.B);
                    var hwnd = new System.Windows.Interop.WindowInteropHelper(dialog);
                    if (colorDlg.ShowDialog(new DialogOwner(hwnd.Handle)) == System.Windows.Forms.DialogResult.OK)
                        showChoice(Color.FromRgb(colorDlg.Color.R,colorDlg.Color.G,colorDlg.Color.B));
                }
                dialog.Activate();
            }));
            bottom.Children.Add(Button("Применить", true, () => { SetGroupRgb(chosen.R + "," + chosen.G + "," + chosen.B); dialog.DialogResult = true; }));
            bottom.Children.Add(Button("Отмена", false, () => dialog.DialogResult = false));
            Grid.SetRow(bottom, 2); layout.Children.Add(bottom);
            dialog.Content = layout; dialog.ShowDialog(); RestoreStudioFocus();
        }

        private UIElement PlacementPage()
        {
            Grid layout = GridCols(1.15, 2.5);
            StackPanel left = Stack(false);
            left.Children.Add(Text("Группы", 21, true, foreground));
            placementGroups = new ListBox { Height = 430, Margin = new Thickness(0, 17, 8, 0), Foreground = Brush(foreground), Background = Brush(surface), BorderThickness = new Thickness(0) };
            placementGroups.SelectionChanged += (s, e) => { if (!populating) SelectGroup(placementGroups.SelectedIndex, true); };
            left.Children.Add(placementGroups);
            StackPanel actions = Stack(true); actions.Margin = new Thickness(0, 12, 0, 0);
            actions.Children.Add(Button("+ Группа", true, () => Send("GroupCreate", "")));
            actions.Children.Add(Button("Удалить", false, () => Send("GroupDelete", "")));
            left.Children.Add(actions); Col(layout, left, 0);
            StackPanel editor = Stack(false); editor.Margin = new Thickness(16, 0, 0, 0);
            editor.Children.Add(Text("Расстановка", 21, true, foreground));
            StackPanel presets = Stack(true); presets.Margin = new Thickness(0, 12, 0, 4);
            presetName = Input(""); presetName.Width = 140; presetName.Margin = new Thickness(0,0,8,8); presets.Children.Add(presetName);
            presets.Children.Add(Button("Сохранить группы в пресет", false, () => { FlushGroupChanges(); Send("PresetSave", ""); }));
            presetChoice = Combo(); presetChoice.Width = 175;
            foreach (string pName in presetNameCache) presetChoice.Items.Add(pName);
            presets.Children.Add(presetChoice);
            presets.Children.Add(Button("Загрузить группы", false, () => { FlushGroupChanges(); Send("PresetLoad", ""); }));
            editor.Children.Add(Section("Пресеты групп", presets));
            Grid fields = GridCols(1.3, 1, 1); fields.Margin = new Thickness(0, 12, 0, 12);
            StackPanel f0 = Stack(false); Label(f0, "Имя группы"); groupName = Input(""); f0.Children.Add(groupName);
            Label(f0, "Цвет группы на RGB-маске");
            StackPanel colorRow = Stack(true);
            groupRgb = Input("255,0,0"); groupRgb.Width = 114;
            groupRgb.TextChanged += (s, e) => { UpdateGroupColorSwatch(); ScheduleGroupSave(); };
            colorRow.Children.Add(groupRgb);
            groupColorSwatch = new Border { Width = 32, Height = 32, CornerRadius = new CornerRadius(5), BorderBrush = Brush(muted), BorderThickness = new Thickness(1), Margin = new Thickness(1, 0, 8, 0) };
            colorRow.Children.Add(groupColorSwatch);
            Button pickButton = Button("Пипетка…", false, () => PickGroupColorFromMask());
            pickButton.MinHeight = 31;
            colorRow.Children.Add(pickButton);
            f0.Children.Add(colorRow);
            UpdateGroupColorSwatch();
            StackPanel f1 = Stack(false); Label(f1, "Плотность, шт/га"); groupDensity = StepInput("350", f1, 25.0, 0.0, 1000000.0);
            Label(f1, "Масштаб от"); groupMin = ScaleInput("0.80", f1);
            StackPanel f2 = Stack(false); Label(f2, "Мин. дистанция, м"); groupInside = StepInput("2", f2, 1.0, 0.0, 10000.0);
            Label(f2, "Масштаб до"); groupMax = ScaleInput("1.20", f2);
            Col(fields, f0, 0); Col(fields, f1, 1); Col(fields, f2, 2);
            editor.Children.Add(Section("Параметры группы", fields));
            StackPanel toggles = Stack(true); toggles.Margin = new Thickness(8, 0, 0, 8);
            groupRotation = Check("Случайный Z-поворот"); groupAlign = Check("Выравнивание по нормали");
            toggles.Children.Add(groupRotation); toggles.Children.Add(groupAlign);
            toggles.Children.Add(Text("Наклон °", 12, false, muted)); groupTilt = StepInput("5", toggles, 1.0, 0.0, 30.0);
            editor.Children.Add(toggles);
            foreach (TextBox field in new[] { groupName, groupDensity, groupInside, groupTilt, groupMin, groupMax })
                field.TextChanged += (s,e) => ScheduleGroupSave();
            foreach (CheckBox cb in new[] { groupRotation, groupAlign })
            {
                cb.Checked += (s,e) => ScheduleGroupSave();
                cb.Unchecked += (s,e) => ScheduleGroupSave();
            }
            editor.Children.Add(Text("Плотность задаёт количество, минимальная дистанция — ограничение сближения. Все изменения сохраняются автоматически; веса моделей не меняют плотность.", 12, false, muted));
            editor.Children.Add(Text("Состав группы (модели библиотеки)", 14, true, foreground));
            groupMembers = new ListBox { Height = 250, Margin = new Thickness(0, 12, 10, 14), Background = Brush(surface), Foreground = Brush(foreground), BorderThickness = new Thickness(0) };
            editor.Children.Add(groupMembers);
            editor.Children.Add(Text("Вес модели: 100% — обычная частота, 25% — в 4 раза реже одной модели со 100%. 0% — не использовать.", 11, false, muted));
            groupCountLabel = Text("Создай группу и добавь модели из библиотеки", 12, false, muted); editor.Children.Add(groupCountLabel);
            StackPanel run = Stack(true); run.Margin = new Thickness(0, 20, 0, 0);
            run.Children.Add(Button("Подготовить LOD группы", false, () => Send("PrepareGroup", "")));
            run.Children.Add(Button("ПОДГОТОВИТЬ И СГЕНЕРИРОВАТЬ", true, () => { FlushGroupChanges(); Send("Generate", ""); }));
            run.Children.Add(Button("Удалить всё сгенерированное", false, () => Send("DeleteGenerated", "")));
            editor.Children.Add(run); Col(layout, Scroll(editor), 1);
            RefreshPlacementGroupControls(); return layout;
        }
        private UIElement ExportPage()
        {
            StackPanel all = Stack(false);
            all.Children.Add(Text("Экспорт в X-Ray SDK", 22, true, foreground));
            all.Children.Add(new Border { Height = 18 });
            StackPanel form = Stack(false);
            Label(form, "scene_object.part (настраивается на вкладке «Проект»)");
            exportPartInfo = Text("Путь ещё не задан. Открой вкладку «Проект».", 13, false, foreground);
            exportPartInfo.TextWrapping = TextWrapping.Wrap;
            form.Children.Add(Box(exportPartInfo, panel, 12, 6));
            Label(form, "Префикс для новых имён объектов"); exportPrefix = Input(""); form.Children.Add(exportPrefix);
            exportSelected = Check("Экспортировать только выделенные объекты"); form.Children.Add(exportSelected);
            exportStats = Text("Проверка ещё не запускалась", 15, false, muted); exportStats.Margin = new Thickness(0, 20, 0, 20); form.Children.Add(exportStats);
            StackPanel actions = Stack(true);
            actions.Children.Add(Button("Проверить объекты", false, () => Send("ExportCheck", "")));
            actions.Children.Add(Button("ЭКСПОРТИРОВАТЬ В .PART", true, () => Send("ExportRun", "")));
            form.Children.Add(actions);
            form.Children.Add(Text("Действующий MAXScript создаёт резервную копию и проверяет reference_name перед записью.", 12, false, muted));
            all.Children.Add(Section("Передача scene_object.part", form));
            return Scroll(all);
        }
        private void RefreshLibraryGroupControls()
        {
            if (libraryGroup == null) return;
            populating = true; libraryGroup.Items.Clear();
            foreach (GroupView g in groups) libraryGroup.Items.Add(g.Name);
            if (groups.Count > 0) libraryGroup.SelectedIndex = Math.Max(0, Math.Min(currentGroup, groups.Count - 1));
            populating = false; RefreshMembers();
        }
        private void RefreshPlacementGroupControls()
        {
            if (placementGroups == null) return;
            populating = true; placementGroups.Items.Clear();
            foreach (GroupView g in groups) placementGroups.Items.Add(g.Name + "  ·  " + g.Density.ToString("0", CultureInfo.InvariantCulture) + "/га");
            if (groups.Count > 0) placementGroups.SelectedIndex = Math.Max(0, Math.Min(currentGroup, groups.Count - 1));
            populating = false; LoadGroupFields();
        }
        private void SelectGroup(int index, bool notify)
        {
            if (index < 0 || index >= groups.Count) return;
            if (currentGroup != index) FlushGroupChanges();
            currentGroup = index; LoadGroupFields(); RefreshMembers();
            if (notify) Send("GroupSelected", (index + 1).ToString(CultureInfo.InvariantCulture));
        }
        private void LoadGroupFields()
        {
            if (groupName == null || currentGroup < 0 || currentGroup >= groups.Count) return;
            GroupView g = groups[currentGroup];
            populating = true;
            groupName.Text = g.Name; groupRgb.Text = g.Rgb;
            groupDensity.Text = g.Density.ToString("0.##", CultureInfo.InvariantCulture);
            groupMin.Text = g.MinScale.ToString("0.00", CultureInfo.InvariantCulture);
            groupMax.Text = g.MaxScale.ToString("0.00", CultureInfo.InvariantCulture);
            groupInside.Text = g.Inside.ToString("0.##", CultureInfo.InvariantCulture);
            groupTilt.Text = g.Tilt.ToString("0.##", CultureInfo.InvariantCulture);
            groupRotation.IsChecked = g.Rotation; groupAlign.IsChecked = g.Align;
            populating = false;
        }
        private void UpdateGroupColorSwatch()
        {
            if (groupColorSwatch == null || groupRgb == null) return;
            string[] rgb = groupRgb.Text.Split(new[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries);
            int r, g, b;
            if (rgb.Length == 3 && int.TryParse(rgb[0], out r) && int.TryParse(rgb[1], out g) && int.TryParse(rgb[2], out b) &&
                r >= 0 && r <= 255 && g >= 0 && g <= 255 && b >= 0 && b <= 255)
            {
                groupColorSwatch.Background = Brush(Color.FromRgb((byte)r, (byte)g, (byte)b));
            }
            else groupColorSwatch.Background = Brush(panel);
        }
        public void SetGroupRgb(string rgb)
        {
            if (groupRgb != null) groupRgb.Text = rgb ?? "255,0,0";
            UpdateGroupColorSwatch();
        }
        private void RefreshMembers()
        {
            int index = currentGroup;
            if (libraryGroup != null && libraryGroup.SelectedIndex >= 0) index = libraryGroup.SelectedIndex;
            if (libraryMembers != null)
            {
                libraryMembers.Items.Clear();
                if (index >= 0 && index < groups.Count)
                    foreach (string s in groups[index].Refs) libraryMembers.Items.Add(s);
            }
            if (groupMembers != null)
            {
                groupMembers.Items.Clear();
                if (currentGroup >= 0 && currentGroup < groups.Count)
                {
                    GroupView g = groups[currentGroup];
                    for (int i = 0; i < g.Refs.Count; i++)
                    {
                        int idx = i;
                        int rowGroup = currentGroup;
                        double weight = i < g.Weights.Count ? g.Weights[i] : 100.0;
                        Grid line = new Grid { Margin = new Thickness(4, 5, 4, 5) };
                        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2, GridUnitType.Star) });
                        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.4, GridUnitType.Star) });
                        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(64) });
                        TextBlock filename = Text(g.Refs[i].Substring(g.Refs[i].LastIndexOf('\\')+1), 12, false, foreground);
                        filename.ToolTip = g.Refs[i]; Grid.SetColumn(filename, 0); line.Children.Add(filename);
                        Slider slide = new Slider { Minimum = 0, Maximum = 100, Value = weight, TickFrequency = 5, IsSnapToTickEnabled = true, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 8, 0) };
                        Grid.SetColumn(slide, 1); line.Children.Add(slide);
                        TextBox weightText = Input(weight.ToString("0", CultureInfo.InvariantCulture)); weightText.Width = 60;
                        Grid.SetColumn(weightText, 2); line.Children.Add(weightText);
                        bool updatingWeight = false;
                        slide.ValueChanged += (s,e) => { if (updatingWeight) return; updatingWeight=true; weightText.Text = slide.Value.ToString("0", CultureInfo.InvariantCulture); updatingWeight=false; };
                        Action commit = () => {
                            double w;
                            if (!double.TryParse(weightText.Text.Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out w)) return;
                            w = Math.Max(0, Math.Min(100, w));
                            if (idx >= g.Weights.Count) { while (g.Weights.Count <= idx) g.Weights.Add(100); }
                            g.Weights[idx] = w;
                            Send("MemberWeight", (rowGroup + 1).ToString(CultureInfo.InvariantCulture) + "|" + (idx + 1).ToString(CultureInfo.InvariantCulture) + "|" + w.ToString(CultureInfo.InvariantCulture));
                        };
                        slide.PreviewMouseLeftButtonUp += (s,e) => commit();
                        slide.PreviewKeyUp += (s,e) => commit();
                        weightText.PreviewKeyDown += (s,e) => { if (e.Key == Key.Enter) { commit(); e.Handled = true; } };
                        weightText.LostKeyboardFocus += (s,e) => { double w; if (double.TryParse(weightText.Text.Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out w)) { slide.Value = Math.Max(0,Math.Min(100,w)); commit(); } };
                        groupMembers.Items.Add(line);
                    }
                }
            }
            if (groupCountLabel != null && currentGroup >= 0 && currentGroup < groups.Count)
                groupCountLabel.Text = groups[currentGroup].Refs.Count + " моделей в группе";
        }
        // Public bridge for MAXScript (deliberately primitive argument types; no JSON/eval).
        public void LoadAssetCatalog(string path)
        {
            assets.Clear();
            selectedAssets.Clear();
            if (File.Exists(path))
            {
                foreach (string line in File.ReadAllLines(path))
                {
                    string item = line.Trim();
                    if (item.Length > 0 && !item.StartsWith("#")) assets.Add(item.Replace('/', '\\'));
                }
            }
            RefreshFolders();
            RefreshAssetCards();
        }
        public void SetThumbnailDirectory(string path) { thumbnailDirectory = path ?? ""; thumbnailCache.Clear(); RefreshAssetCards(); }
        public string SelectedAssetRefs { get { return string.Join("|", selectedAssets.ToArray()); } }
        public int SelectedLibraryGroup { get { return libraryGroup == null ? currentGroup : libraryGroup.SelectedIndex; } }
        public int SelectedGroup { get { return currentGroup; } }
        public int SelectedMember { get { return libraryMembers == null ? -1 : libraryMembers.SelectedIndex; } }
        public void ClearGroups() { groups.Clear(); currentGroup = -1; }
        public void AddGroup(string name, string rgb, double density, double minScale, double maxScale, double inside, double tilt, bool rotation, bool align)
        {
            groups.Add(new GroupView { Name = name, Rgb = rgb, Density = density, MinScale = minScale, MaxScale = maxScale, Inside = inside, Tilt = tilt, Rotation = rotation, Align = align });
        }
        public void AddGroupAssetWeighted(int groupIndex, string id, double weight)
        {
            if (groupIndex >= 0 && groupIndex < groups.Count)
            {
                groups[groupIndex].Refs.Add(id);
                groups[groupIndex].Weights.Add(Math.Max(0, Math.Min(100, weight)));
            }
        }
        public void EndGroups(int selectedIndex)
        {
            currentGroup = groups.Count == 0 ? -1 : Math.Min(Math.Max(selectedIndex, 0), groups.Count - 1);
            RefreshPlacementGroupControls(); RefreshLibraryGroupControls();
        }
        public void SetProject(string terrainName, string maskName, double unitsPerMeter, int seedNumber, bool useSub, string sdkRoot, string partPath, string alphaInfo)
        {
            if (terrain != null) terrain.Text = terrainName;
            if (mask != null) mask.Text = maskName;
            SetMaskSource(maskName);
            populating = true;
            if (scale != null) scale.Text = unitsPerMeter.ToString("0.##", CultureInfo.InvariantCulture);
            if (seed != null) seed.Text = seedNumber.ToString(CultureInfo.InvariantCulture);
            if (subobject != null) subobject.IsChecked = useSub;
            if (sdk != null) sdk.Text = sdkRoot;
            if (partProject != null) partProject.Text = partPath;
            if (projectSummary != null) projectSummary.Text = alphaInfo;
            if (exportPartInfo != null) exportPartInfo.Text = string.IsNullOrWhiteSpace(partPath) ? "Путь ещё не задан. Открой вкладку «Проект»." : partPath;
            populating = false;
        }
        public string ProjectScale { get { return scale == null ? "1.0" : scale.Text; } }
        public string ProjectSeed { get { return seed == null ? "1" : seed.Text; } }
        public bool ProjectSubObject { get { return subobject != null && subobject.IsChecked == true; } }
        public string ProjectSdkRoot { get { return sdk == null ? "" : sdk.Text; } }
        public void SetSdkRoot(string root) { if (sdk != null) sdk.Text = root ?? ""; }
        public string ProjectPartPath { get { return partProject == null ? "" : partProject.Text; } }
        public string PresetName { get { return presetName == null ? "" : presetName.Text; } }
        public string SelectedPreset { get { return presetChoice == null || presetChoice.SelectedItem == null ? "" : presetChoice.SelectedItem.ToString(); } }
        public void ClearPresets() { presetNameCache.Clear(); if (presetChoice != null) presetChoice.Items.Clear(); }
        public void AddPreset(string name) {
            if (!presetNameCache.Contains(name)) presetNameCache.Add(name);
            if (presetChoice != null && !presetChoice.Items.Contains(name)) presetChoice.Items.Add(name);
        }
        public string GroupName { get { return groupName == null ? "" : groupName.Text; } }
        public string GroupRgb { get { return groupRgb == null ? "" : groupRgb.Text; } }
        public string GroupDensity { get { return groupDensity == null ? "" : groupDensity.Text; } }
        public string GroupMin { get { return groupMin == null ? "" : groupMin.Text; } }
        public string GroupMax { get { return groupMax == null ? "" : groupMax.Text; } }
        public string GroupInside { get { return groupInside == null ? "" : groupInside.Text; } }
        public string GroupTilt { get { return groupTilt == null ? "" : groupTilt.Text; } }
        public bool GroupRotation { get { return groupRotation != null && groupRotation.IsChecked == true; } }
        public bool GroupAlign { get { return groupAlign != null && groupAlign.IsChecked == true; } }
        public string ExportPartPath { get { return partProject == null ? "" : partProject.Text; } }
        public string ExportPrefix { get { return exportPrefix == null ? "" : exportPrefix.Text; } }
        public bool ExportSelectedOnly { get { return exportSelected != null && exportSelected.IsChecked == true; } }
        public void SetExportState(string info) { if (exportStats != null) exportStats.Text = info; }
        public void SetStatus(string message) { if (statusLabel != null) statusLabel.Text = message; }
        public void RefreshUI() { ShowPage(activeTab); }
        public void InvalidateThumbnails() { thumbnailCache.Clear(); RefreshAssetCards(); }
    }
}
