"""Письма .eml: адресаты, тема, текст и HTML-части. Вложения удаляются — в них могут быть ПДн."""
from __future__ import annotations

from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
from email.utils import getaddresses
from pathlib import Path

from ..kinds import Kind
from . import layout, views
from .base import Context, Result, UnreadableFile, clip, output_path
from .markup import clean_markup
from .plaintext import clean_lines

EXTENSIONS = {".eml"}
_ADDRESS_HEADERS = ("From", "To", "Cc", "Bcc", "Reply-To", "Sender", "Delivered-To", "Return-Path")
_LABELS = {"From": "От", "To": "Кому", "Cc": "Копия", "Bcc": "Скрытая копия", "Reply-To": "Ответить",
           "Sender": "Отправитель", "Delivered-To": "Доставлено", "Return-Path": "Обратный адрес", "Subject": "Тема"}
_DROP_HEADERS = ("Received", "X-Originating-IP", "X-Sender-IP", "DKIM-Signature", "ARC-Seal",
                 "ARC-Message-Signature", "ARC-Authentication-Results", "Authentication-Results", "Message-ID",
                 "X-Google-Smtp-Source", "X-Received")


def process(src: Path, out_dir: Path, ctx: Context) -> Result:
    try:
        msg: EmailMessage = BytesParser(policy=policy.default).parsebytes(src.read_bytes())  # type: ignore[assignment]
    except Exception as e:  # noqa: BLE001
        raise UnreadableFile(str(e)) from e
    preview: list[str] = []
    head: list[tuple[str, str]] = []        # поля письма для редактора
    body_view: list = []
    for h in _DROP_HEADERS:
        del msg[h]
    for h in _ADDRESS_HEADERS:
        values = msg.get_all(h)
        if not values:
            continue
        del msg[h]
        for value in values:
            shown, encoded = [], []
            for name, addr in getaddresses([str(value)]):
                tag_name = ctx.tag(Kind.PERSON, name) if name.strip() else ""
                tag_addr = ctx.tag(Kind.EMAIL, addr) if addr.strip() else ""
                label = f"{tag_name} {tag_addr}".strip()
                shown.append(f"{tag_name} <{tag_addr}>" if tag_name else tag_addr)
                # [EMAIL_1] — невалидный адрес для RFC 5322; метки — в имени, адрес — заведомо несуществующий
                encoded.append(f'"{label}" <hidden@nekto.invalid>')
            msg[h] = ", ".join(encoded)
            preview.append(f"{h}: {', '.join(shown)}")
            head.append((_LABELS[h], ", ".join(shown)))
    if msg["Subject"]:
        subject = ctx.clean_text(str(msg["Subject"]))
        msg.replace_header("Subject", subject)
        preview.append(f"Subject: {subject}")
        head.append((_LABELS["Subject"], subject))
    preview.append("")
    removed = 0
    for part in list(msg.walk()):
        if part.is_multipart():
            continue
        if part.get_content_disposition() == "attachment":
            removed += 1
            continue
        ctype = part.get_content_type()
        if ctype == "text/plain":
            body = clean_lines(part.get_content(), ctx, 0.0, 0.5)
            part.set_content(body, subtype="plain", charset="utf-8", cte="8bit")
            preview.append(body)
            body_view += views.text_blocks(body, markdown=False)
        elif ctype == "text/html":
            body, visible = clean_markup(part.get_content(), ctx, 0.5, 1.0)
            part.set_content(body, subtype="html", charset="utf-8", cte="8bit")
            if not any(p for p in preview[-1:] if p):
                preview.append(visible)
                body_view += views.html_blocks(body)
    if removed:
        _strip_attachments(msg)
    dst = output_path(src, out_dir)
    dst.write_bytes(msg.as_bytes(policy=policy.SMTP))
    notes = [f"удалено вложений: {removed}"] if removed else []
    view = [layout.fields(head), *body_view]
    if removed:
        view.append(layout.note(f"Вложения удалены: {removed}. В них могли быть персональные данные, "
                                f"а проверить их здесь нельзя — отправьте их отдельными файлами."))
    return Result(dst, clip("\n".join(preview)), ctx.replaced, notes, layout=layout.compact(view))


def _strip_attachments(msg: EmailMessage) -> None:
    if not msg.is_multipart():
        return
    keep = [p for p in msg.iter_parts() if p.get_content_disposition() != "attachment"]
    for p in keep:
        if p.is_multipart():
            _strip_attachments(p)  # type: ignore[arg-type]
    msg.set_payload(keep)
