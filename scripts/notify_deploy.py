#!/usr/bin/env python3
"""Emails deploy status after each auto-deploy. stdlib-only, no third-party deps."""
import os
import smtplib
import sys
from datetime import datetime, timezone
from email.mime.text import MIMEText

SMTP_HOST = "smtp.gmail.com"
SMTP_PORT = 587


def main():
    gmail_address = os.environ.get("GMAIL_ADDRESS")
    gmail_app_password = os.environ.get("GMAIL_APP_PASSWORD")
    if not gmail_address or not gmail_app_password:
        print("notify_deploy: GMAIL_ADDRESS/GMAIL_APP_PASSWORD not set, skipping notification.")
        return

    status = os.environ.get("DEPLOY_STATUS", "unknown")
    commit_sha = os.environ.get("COMMIT_SHA", "unknown")
    commit_msg = os.environ.get("COMMIT_MSG", "")
    manual_step_needed = os.environ.get("MANUAL_STEP_NEEDED") == "true"
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    subject = f"[home-infra] deploy {status} — {commit_sha[:7]}"
    if manual_step_needed:
        subject += " (accion manual requerida)"
    body = (
        f"Status:  {status}\n"
        f"Commit:  {commit_sha}\n"
        f"Message: {commit_msg}\n"
        f"When:    {now}\n"
    )
    if manual_step_needed:
        body += (
            "\nEste push modifico init.sh o algun scripts/*.sh. Esos cambios NO se\n"
            "aplican solos -- entra por SSH a la rasp y corre ./init.sh (o el script\n"
            "puntual que cambio) manualmente.\n"
        )

    msg = MIMEText(body)
    msg["Subject"] = subject
    msg["From"] = gmail_address
    msg["To"] = gmail_address

    with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as smtp:
        smtp.starttls()
        smtp.login(gmail_address, gmail_app_password)
        smtp.sendmail(gmail_address, [gmail_address], msg.as_string())

    print("notify_deploy: notification sent.")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        # A notification failure must never fail the whole workflow run.
        print(f"notify_deploy: failed to send notification: {exc}", file=sys.stderr)
        sys.exit(0)
