"""
SNS -> Slack.  roadmap.md Phase 11.

Phase 11 decided signals go to Slack and operational alerts go to email, and
this is the Slack half. It is deliberately small: SNS delivers, this reshapes,
Slack receives.

WHY A LAMBDA AND NOT AN SNS HTTPS SUBSCRIPTION
    SNS can POST to an HTTPS endpoint directly, and a Slack webhook is one. It
    does not work: SNS sends its own JSON envelope, and Slack expects a payload
    with a `text` or `blocks` key. Slack answers 400, SNS retries for an hour
    and gives up, and nothing anywhere says the alert was lost. Something has to
    translate, and a Lambda is the smallest thing that can.

WHY THE WEBHOOK IS IN SECRETS MANAGER
    A Slack incoming webhook URL is a bearer credential -- anyone holding it can
    post to the channel as this app, with no further authentication. In a Lambda
    environment variable it is visible to anyone with lambda:GetFunction, which
    is a much wider set of principals than secretsmanager:GetSecretValue on one
    secret. It is also the kind of value that ends up in a terminal scrollback
    during an incident.

    Fetched once per container and cached: a warm invocation should not spend a
    Secrets Manager call, and Secrets Manager charges per 10,000 API calls.

    THE CACHE HAS NO INVALIDATION, AND ROTATION IS WHERE THAT BITES. Pasting a
    new webhook into the secret does not reach a container that is already warm
    -- it keeps posting with the old URL until Lambda recycles it, which can be
    minutes or hours. This cost a live debugging session at the Phase 11 apply:
    the secret was correct, the direct POST returned 200, and the Lambda kept
    failing, because the two were not talking to the same URL.

    So a rotation is two steps, not one: set the secret, then force new
    execution environments -- rewriting the function's configuration with
    IDENTICAL values does it, and leaves no Terraform drift:

        aws lambda update-function-configuration --function-name <fn> \
            --environment "Variables={SLACK_WEBHOOK_SECRET_ARN=<same arn>}"

    A TTL was considered and declined: it would spend a Secrets Manager call on
    a schedule to fix a problem that happens by hand, roughly never, and it
    would make the failure intermittent rather than absolute -- which is harder
    to diagnose, not easier.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

import boto3

SECRET_ARN = os.environ["SLACK_WEBHOOK_SECRET_ARN"]
SECRET_JSON_KEY = os.environ.get("SLACK_WEBHOOK_SECRET_KEY", "webhook_url")

_secrets = boto3.client("secretsmanager")
_webhook_cache: dict[str, str] = {}


def _webhook_url() -> str:
    if "url" not in _webhook_cache:
        raw = _secrets.get_secret_value(SecretId=SECRET_ARN)["SecretString"]
        try:
            _webhook_cache["url"] = json.loads(raw)[SECRET_JSON_KEY]
        except (json.JSONDecodeError, KeyError, TypeError):
            # A secret stored as a bare URL rather than as JSON. Accepted,
            # because the alternative is that the alerting path fails on the day
            # someone pasted the value in the obvious way.
            _webhook_cache["url"] = raw.strip()
    return _webhook_cache["url"]


def _format(subject: str, message: str) -> dict:
    """Turn one SNS record into a Slack payload.

    The message may be JSON (a CloudWatch alarm) or plain text (a Step Functions
    NotifyFailure). Both are handled, and an unparseable message is posted
    verbatim rather than dropped -- an alert that cannot be formatted is still
    an alert.
    """
    try:
        payload = json.loads(message)
    except (json.JSONDecodeError, TypeError):
        return {"text": f"*{subject or 'Alert'}*\n```{message[:2500]}```"}

    if "AlarmName" in payload:
        state = payload.get("NewStateValue", "?")
        emoji = {"ALARM": ":rotating_light:", "OK": ":white_check_mark:"}.get(state, ":grey_question:")
        return {
            "text": f"{emoji} *{payload['AlarmName']}* -> {state}",
            "blocks": [
                {"type": "section", "text": {"type": "mrkdwn",
                                             "text": f"{emoji} *{payload['AlarmName']}* → *{state}*"}},
                {"type": "context", "elements": [
                    {"type": "mrkdwn", "text": payload.get("NewStateReason", "no reason given")[:2000]}
                ]},
            ],
        }

    return {"text": f"*{subject or 'Signal'}*\n```{json.dumps(payload, indent=2)[:2500]}```"}


def handler(event, _context=None):
    url = _webhook_url()
    delivered, failed = 0, []

    for record in event.get("Records", []):
        sns = record.get("Sns", {})
        body = json.dumps(_format(sns.get("Subject", ""), sns.get("Message", ""))).encode()
        request = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=10) as resp:
                if resp.status != 200:
                    failed.append(f"slack returned {resp.status}")
                else:
                    delivered += 1
        except urllib.error.HTTPError as exc:
            # Slack puts the ACTUAL reason in the response body, and str(exc)
            # throws it away -- it yields "HTTP Error 500: Internal Server
            # Error" and nothing else. The body says `messages_tab_disabled`,
            # or `no_service`, or `channel_is_archived`: the difference between
            # "someone pointed the webhook at a DM" and "someone revoked it".
            #
            # This is not hypothetical. The Phase 11 verification failed with a
            # bare 500, and the reason had to be recovered by replaying the POST
            # by hand from a laptop. The log should have said it the first time.
            try:
                detail = exc.read().decode("utf-8", "replace").strip()[:200]
            except Exception:  # noqa: BLE001
                detail = "<body unreadable>"
            failed.append(f"HTTP {exc.code}: {detail or '<empty body>'}")
        except Exception as exc:  # noqa: BLE001
            failed.append(str(exc))

    if failed:
        # Raise, so the invocation fails and lands in this function's Errors
        # metric -- which has its own alarm on the OPS topic, reaching email.
        # A notifier that fails silently is worse than no notifier: it converts
        # "we were not told" into "we believe we were told".
        raise RuntimeError(f"{len(failed)} of {delivered + len(failed)} deliveries failed: {failed[0]}")

    return {"delivered": delivered}
