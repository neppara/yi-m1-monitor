"""
Design system for the YI M1 Monitor app.

Single source of truth for the app's visual language: colors, spacing, radii,
type scale, plus a Qt stylesheet built from them. Kept deliberately small and
declarative so the same token vocabulary can be mirrored 1:1 in the planned iOS
companion app (see app/ARCHITECTURE.md roadmap) - the values here ARE the shared
design system; the two apps just render them in their own native frameworks.

Direction (approved 2026-07-07): dark "pro-monitor" aesthetic, monochrome with a
single amber accent. Red is reserved exclusively for the recording state (a
universal convention, not a second accent).
"""


class Color:
    # Surfaces, darkest (page) to lightest (raised controls).
    BG = "#0c0d0f"            # window / page background
    SURFACE = "#16181b"       # chips, buttons, panels
    SURFACE_2 = "#1e2124"     # raised / hover
    LIVE_BG = "#141517"       # live-view letterbox area

    # Hairlines.
    HAIRLINE = "#2a2d31"      # default 0.5px divider / control border
    HAIRLINE_SOFT = "#1c1f22"  # very subtle section separator

    # Text tiers.
    TEXT = "#f3f4f6"          # primary
    TEXT_2 = "#9ba1a8"        # secondary
    TEXT_3 = "#63696f"        # muted captions / disabled

    # The single accent + reserved semantic colors.
    ACCENT = "#f5a623"        # amber - active/selected states, focus, guides
    ACCENT_DIM = "#8a6320"    # amber, muted (pressed / low-emphasis active)
    RECORD = "#ff3b30"        # recording ONLY
    OK = "#34c759"            # connection "connected" dot (status only)


class Radius:
    SM = 8
    MD = 11
    LG = 14


class Space:
    XS = 4
    SM = 8
    MD = 12
    LG = 16
    XL = 20


class Font:
    # Point sizes for the type scale; the iOS port uses the same scale.
    CAPTION = 11
    SMALL = 12
    BODY = 13
    VALUE = 14
    HEADING = 16
    # A concrete family Qt resolves without warnings on macOS. (The CSS token
    # "-apple-system"/SF Pro is ideal typographically but Qt's QFont(family) can't
    # parse a CSS stack - it treats the whole string as one missing family name.)
    FAMILY = "Helvetica Neue"


def app_stylesheet() -> str:
    """Base QSS applied once to the QApplication. Widget-specific looks (shutter
    button, mode toggle, guide toggles, setting chips) are applied per-widget via
    objectName selectors so this stays a readable, single-place theme definition."""
    return """
    QWidget {{
        background-color: {bg};
        color: {text};
        font-family: {family};
        font-size: {body}px;
    }}

    QToolTip {{
        background-color: {surface2};
        color: {text};
        border: 1px solid {hairline};
        padding: 4px 8px;
    }}

    /* ---- generic buttons (secondary/ghost look) ---- */
    QPushButton {{
        background-color: {surface};
        color: {text};
        border: 1px solid {hairline};
        border-radius: {r_sm}px;
        padding: 7px 14px;
    }}
    QPushButton:hover {{ background-color: {surface2}; }}
    QPushButton:pressed {{ background-color: {surface}; }}
    QPushButton:disabled {{ color: {text3}; border-color: {hairline_soft}; }}

    /* ---- dropdowns (setting pickers) ---- */
    QComboBox {{
        background-color: {surface};
        color: {text};
        border: 1px solid {hairline};
        border-radius: {r_sm}px;
        padding: 6px 10px;
    }}
    QComboBox:hover {{ border-color: {accent}; }}
    QComboBox::drop-down {{ border: none; width: 18px; }}
    QComboBox QAbstractItemView {{
        background-color: {surface2};
        color: {text};
        border: 1px solid {hairline};
        selection-background-color: {accent};
        selection-color: {bg};
        outline: none;
    }}

    /* ---- labels ---- */
    QLabel {{ background: transparent; color: {text}; }}
    QLabel[tier="secondary"] {{ color: {text2}; }}
    QLabel[tier="muted"] {{ color: {text3}; font-size: {caption}px; }}

    /* ---- progress bar ---- */
    QProgressBar {{
        background-color: {surface};
        border: 1px solid {hairline};
        border-radius: {r_sm}px;
        text-align: center;
        color: {text};
        height: 16px;
    }}
    QProgressBar::chunk {{
        background-color: {accent};
        border-radius: {r_sm}px;
    }}

    /* ---- list (file browser) ---- */
    QListWidget {{
        background-color: {surface};
        border: 1px solid {hairline};
        border-radius: {r_sm}px;
        outline: none;
    }}
    QListWidget::item {{ padding: 6px 8px; }}
    QListWidget::item:selected {{ background-color: {accent}; color: {bg}; }}

    /* ---- menus (Connection) ----
       Each item is drawn as an outlined button with uniform margins (2026-07-20 user
       feedback: default QMenu items ran together with uneven gaps and were hard to tell
       apart). Separators keep the grouping without adding vertical jitter. */
    QMenu {{
        background-color: {surface};
        border: 1px solid {hairline};
        border-radius: {r_sm}px;
        padding: 6px;
    }}
    QMenu::item {{
        background-color: {surface};
        color: {text};
        border: 1px solid {hairline};
        border-radius: {r_sm}px;
        padding: 8px 16px;
        margin: 3px 2px;
    }}
    QMenu::item:selected {{
        border-color: {accent};
        color: {accent};
        background-color: {surface2};
    }}
    QMenu::item:disabled {{
        color: {text3};
        border-color: {hairline_soft};
    }}
    QMenu::separator {{
        height: 1px;
        background-color: {hairline_soft};
        margin: 5px 6px;
    }}

    /* ---- dialogs ---- */
    QDialog {{ background-color: {bg}; }}
    """.format(
        bg=Color.BG, surface=Color.SURFACE, surface2=Color.SURFACE_2,
        hairline=Color.HAIRLINE, hairline_soft=Color.HAIRLINE_SOFT,
        text=Color.TEXT, text2=Color.TEXT_2, text3=Color.TEXT_3,
        accent=Color.ACCENT, family=Font.FAMILY,
        body=Font.BODY, caption=Font.CAPTION,
        r_sm=Radius.SM,
    )


# ---- per-widget style snippets (used by main_window.py) ----

def mode_toggle_qss() -> str:
    """The Photo/Video segmented control container + its two buttons. The active
    segment is marked with objectName-driven state from main_window."""
    return """
    #modeToggle {{ background-color: {surface}; border: 1px solid {hairline}; border-radius: 9px; }}
    #modeToggle QPushButton {{ background: transparent; border: none; border-radius: 7px; color: {text2}; padding: 6px 18px; }}
    #modeToggle QPushButton:checked {{ background-color: {hairline}; color: {text}; }}
    """.format(surface=Color.SURFACE, hairline=Color.HAIRLINE, text=Color.TEXT, text2=Color.TEXT_2)


def guide_toggle_qss(active: bool) -> str:
    """A single guide toggle (Crop / Thirds / Diagonals). Amber when active."""
    if active:
        return "border: 1px solid {a}; color: {a}; background-color: {s};".format(a=Color.ACCENT, s=Color.SURFACE)
    return "border: 1px solid {h}; color: {t}; background-color: {s};".format(h=Color.HAIRLINE, t=Color.TEXT_2, s=Color.SURFACE)


def status_chip_qss() -> str:
    return "background-color: {s}; border: 1px solid {h}; border-radius: {r}px; padding: 5px 10px; color: {t2};".format(
        s=Color.SURFACE, h=Color.HAIRLINE, r=Radius.SM, t2=Color.TEXT_2)
