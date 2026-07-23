"""
Small hand-drawn monochrome line icons for the YI M1 Monitor UI.

Qt has no icon webfont (unlike the web mockups' Tabler set), so these are drawn
with QPainter onto a transparent pixmap and returned as QIcon. Kept simple and
stroke-based so they read at small sizes and recolor cleanly (pass color= for the
amber active state on toggles). Part of the design system alongside theme.py.
"""
from PySide6.QtCore import Qt, QRectF, QPointF
from PySide6.QtGui import QPixmap, QPainter, QPen, QColor, QIcon

import theme


def _folder(p, s):
    m = s * 0.16
    top = s * 0.34
    p.drawPolyline([
        QPointF(m, top), QPointF(m, s - m), QPointF(s - m, s - m),
        QPointF(s - m, top), QPointF(s * 0.46, top),
        QPointF(s * 0.38, s * 0.24), QPointF(m, s * 0.24), QPointF(m, top),
    ])


def _crop(p, s):
    # Two overlapping right angles - the classic crop mark.
    p.drawPolyline([QPointF(s * 0.30, s * 0.10), QPointF(s * 0.30, s * 0.72), QPointF(s * 0.90, s * 0.72)])
    p.drawPolyline([QPointF(s * 0.10, s * 0.30), QPointF(s * 0.72, s * 0.30), QPointF(s * 0.72, s * 0.90)])


def _thirds(p, s):
    m = s * 0.16
    p.drawRect(QRectF(m, m, s - 2 * m, s - 2 * m))
    w = s - 2 * m
    for i in (1, 2):
        p.drawLine(QPointF(m + w * i / 3, m), QPointF(m + w * i / 3, s - m))
        p.drawLine(QPointF(m, m + w * i / 3), QPointF(s - m, m + w * i / 3))


def _diagonals(p, s):
    m = s * 0.16
    p.drawRect(QRectF(m, m, s - 2 * m, s - 2 * m))
    p.drawLine(QPointF(m, m), QPointF(s - m, s - m))
    p.drawLine(QPointF(s - m, m), QPointF(m, s - m))


def _camera(p, s):
    # Body + small viewfinder bump + lens circle.
    body = QRectF(s * 0.12, s * 0.32, s * 0.76, s * 0.44)
    p.drawRoundedRect(body, 3, 3)
    p.drawLine(QPointF(s * 0.30, s * 0.32), QPointF(s * 0.38, s * 0.22))
    p.drawLine(QPointF(s * 0.38, s * 0.22), QPointF(s * 0.52, s * 0.22))
    r = s * 0.13
    cx, cy = s * 0.5, s * 0.55
    p.drawEllipse(QRectF(cx - r, cy - r, 2 * r, 2 * r))


def _video(p, s):
    # A screen/body rectangle with a right-pointing lens wedge - reads as "video".
    body = QRectF(s * 0.12, s * 0.34, s * 0.5, s * 0.34)
    p.drawRoundedRect(body, 3, 3)
    p.drawPolyline([
        QPointF(s * 0.66, s * 0.44), QPointF(s * 0.86, s * 0.34),
        QPointF(s * 0.86, s * 0.68), QPointF(s * 0.66, s * 0.58),
    ])


_DRAW = {
    "folder": _folder,
    "crop": _crop,
    "thirds": _thirds,
    "diagonals": _diagonals,
    "camera": _camera,
    "video": _video,
}


def icon(name: str, size: int = 20, color: str = None) -> QIcon:
    color = color or theme.Color.TEXT_2
    pm = QPixmap(size, size)
    pm.fill(Qt.GlobalColor.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    pen = QPen(QColor(color))
    pen.setWidthF(1.8)
    pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
    pen.setCapStyle(Qt.PenCapStyle.RoundCap)
    p.setPen(pen)
    p.setBrush(Qt.BrushStyle.NoBrush)
    _DRAW[name](p, size)
    p.end()
    return QIcon(pm)
