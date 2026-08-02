import json
import os
import urllib.request
import urllib.error

BASE_URL = os.environ.get("BASE_URL", "").rstrip("/")
DEBUG = os.environ.get("DEBUG", "").lower() == "true"
LONG_LIVED_ACCESS_TOKEN = os.environ.get("LONG_LIVED_ACCESS_TOKEN")

def get_bearer_token(directive):
    scope = None
    if "endpoint" in directive and "scope" in directive["endpoint"]:
        scope = directive["endpoint"]["scope"]
    elif "payload" in directive and "grantee" in directive["payload"]:
        scope = directive["payload"]["grantee"]
    elif "payload" in directive and "scope" in directive["payload"]:
        scope = directive["payload"]["scope"]

    if scope and scope.get("type") == "BearerToken":
        return scope.get("token")

    if DEBUG and LONG_LIVED_ACCESS_TOKEN:
        return LONG_LIVED_ACCESS_TOKEN

    return None

def lambda_handler(event, context):
    if DEBUG:
        print("Event: %s" % json.dumps(event))

    directive = event.get("directive", {})
    token = get_bearer_token(directive)

    if not token:
        return {
            "event": {
                "payload": {
                    "type": "INVALID_AUTHORIZATION_CREDENTIAL",
                    "message": "No bearer token found in directive",
                }
            }
        }

    url = "%s/api/alexa/smart_home" % BASE_URL
    body = json.dumps(event).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": "Bearer %s" % token,
            "Content-Type": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            response_body = resp.read()
            if DEBUG:
                print("Response: %s" % response_body)
            return json.loads(response_body)
    except urllib.error.HTTPError as err:
        error_type = (
            "INVALID_AUTHORIZATION_CREDENTIAL" if err.code in (401, 403) else "INTERNAL_ERROR"
        )
        if DEBUG:
            print("HTTPError %s: %s" % (err.code, err.read()))
        return {
            "event": {
                "payload": {
                    "type": error_type,
                    "message": "Home Assistant returned HTTP %s" % err.code,
                }
            }
        }
    except Exception as exc:
        if DEBUG:
            print("Error: %s" % exc)
        return {
            "event": {
                "payload": {
                    "type": "INTERNAL_ERROR",
                    "message": str(exc),
                }
            }
        }