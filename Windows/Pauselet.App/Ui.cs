using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Pauselet.App;

/// <summary>
/// Small factories for the code-built UI. The app deliberately builds its
/// interface in code rather than XAML bindings: every construct is
/// compile-checked, and nothing fails silently at runtime — which matters for
/// a port developed without a Windows machine to run it on.
/// </summary>
internal static class Ui
{
    public static readonly FontFamily TextFont =
        new("Segoe UI Variable Display, Segoe UI");

    public static TextBlock Text(
        string text, double size, Brush foreground,
        FontWeight? weight = null, TextAlignment alignment = TextAlignment.Left)
    {
        return new TextBlock
        {
            Text = text,
            FontSize = size,
            FontFamily = TextFont,
            Foreground = foreground,
            FontWeight = weight ?? FontWeights.Normal,
            TextAlignment = alignment,
            TextWrapping = TextWrapping.Wrap,
        };
    }

    public static TextBlock Glyph(string sfSymbolName, double size, Brush foreground)
    {
        return new TextBlock
        {
            Text = SymbolMap.Glyph(sfSymbolName),
            FontFamily = SymbolMap.IconFont,
            FontSize = size,
            Foreground = foreground,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
    }

    /// <summary>
    /// A real Button (keyboard- and UIA-operable — accessibility is a
    /// requirement here, not polish) with a flat rounded look, since default
    /// chrome is wrong on both the dark overlay and the themed cards.
    /// </summary>
    public static Button RoundedButton(
        object content, Brush background, Brush foreground,
        Brush? border = null, double cornerRadius = 11,
        Thickness? padding = null, double? minWidth = null)
    {
        var button = new Button
        {
            Content = content,
            Background = background,
            Foreground = foreground,
            BorderBrush = border ?? Brushes.Transparent,
            Padding = padding ?? new Thickness(20, 11, 20, 11),
            FontSize = 15,
            FontFamily = TextFont,
            FontWeight = FontWeights.Medium,
            Cursor = System.Windows.Input.Cursors.Hand,
        };
        if (minWidth is { } width) button.MinWidth = width;
        button.Template = RoundedTemplate(typeof(Button), cornerRadius);
        return button;
    }

    /// <summary>
    /// A ToggleButton with the same flat rounded look as
    /// <see cref="RoundedButton"/>, for the overlay's exercise rows: a real
    /// control (Tab reaches it, Space toggles it, UIA reports it) whose whole
    /// face is the hit target. Return is left for the window so "Return =
    /// Done" holds even while a row has focus.
    /// </summary>
    public static System.Windows.Controls.Primitives.ToggleButton RoundedToggle(
        object content, Brush background, double cornerRadius, Thickness padding)
    {
        var toggle = new System.Windows.Controls.Primitives.ToggleButton
        {
            Content = content,
            Background = background,
            BorderBrush = Brushes.Transparent,
            Padding = padding,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Cursor = System.Windows.Input.Cursors.Hand,
        };
        System.Windows.Input.KeyboardNavigation.SetAcceptsReturn(toggle, false);
        toggle.Template = RoundedTemplate(
            typeof(System.Windows.Controls.Primitives.ToggleButton), cornerRadius,
            contentAlignment: HorizontalAlignment.Stretch
        );
        return toggle;
    }

    private static readonly Dictionary<(Type, double, HorizontalAlignment), ControlTemplate>
        TemplateCache = new();

    /// <summary>
    /// One sealed template per (control type, radius, alignment): templates
    /// are designed to be shared, and the overlay builds a row per exercise
    /// per monitor at the moment a critical reminder fires.
    /// </summary>
    private static ControlTemplate RoundedTemplate(
        Type controlType, double cornerRadius,
        HorizontalAlignment contentAlignment = HorizontalAlignment.Center)
    {
        var key = (controlType, cornerRadius, contentAlignment);
        if (TemplateCache.TryGetValue(key, out var cached)) return cached;
        var template = BuildRoundedTemplate(controlType, cornerRadius, contentAlignment);
        template.Seal();
        TemplateCache[key] = template;
        return template;
    }

    private static ControlTemplate BuildRoundedTemplate(
        Type controlType, double cornerRadius, HorizontalAlignment contentAlignment)
    {
        var borderFactory = new FrameworkElementFactory(typeof(Border));
        borderFactory.SetValue(Border.CornerRadiusProperty, new CornerRadius(cornerRadius));
        borderFactory.SetValue(
            Border.BackgroundProperty,
            new TemplateBindingExtension(Control.BackgroundProperty)
        );
        borderFactory.SetValue(
            Border.BorderBrushProperty,
            new TemplateBindingExtension(Control.BorderBrushProperty)
        );
        borderFactory.SetValue(Border.BorderThicknessProperty, new Thickness(1));
        borderFactory.SetValue(
            Border.PaddingProperty,
            new TemplateBindingExtension(Control.PaddingProperty)
        );

        var contentFactory = new FrameworkElementFactory(typeof(ContentPresenter));
        contentFactory.SetValue(FrameworkElement.HorizontalAlignmentProperty, contentAlignment);
        contentFactory.SetValue(
            FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center
        );
        borderFactory.AppendChild(contentFactory);

        var template = new ControlTemplate(controlType) { VisualTree = borderFactory };
        var pressed = new Trigger
        {
            Property = System.Windows.Controls.Primitives.ButtonBase.IsPressedProperty,
            Value = true,
        };
        pressed.Setters.Add(new Setter(UIElement.OpacityProperty, 0.75));
        template.Triggers.Add(pressed);
        return template;
    }

    /// <summary>
    /// Makes a titled window's non-client chrome follow the app theme: WPF
    /// draws a light title bar regardless of Windows' dark mode unless the
    /// window opts in via DWM. Call once from the constructor.
    /// </summary>
    public static void ApplyThemeChrome(Window window)
    {
        window.SourceInitialized += (_, _) =>
        {
            if (Theme.IsAppLight) return;
            try
            {
                var handle = new System.Windows.Interop.WindowInteropHelper(window).Handle;
                var enabled = 1;
                NativeMethods.DwmSetWindowAttribute(
                    handle, NativeMethods.DWMWA_USE_IMMERSIVE_DARK_MODE,
                    ref enabled, sizeof(int)
                );
            }
            catch
            {
                // A light title bar on a dark window is cosmetic, not fatal.
            }
        };
    }

    /// <summary>An icon-only button with no chrome at all.</summary>
    public static Button IconButton(TextBlock glyph, string? tooltip = null)
    {
        var button = RoundedButton(
            glyph, Brushes.Transparent, glyph.Foreground,
            cornerRadius: 6, padding: new Thickness(4)
        );
        if (tooltip is not null) button.ToolTip = tooltip;
        return button;
    }
}
