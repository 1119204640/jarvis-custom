"""
Google Calendar REST API client — direct HTTP calls to Calendar API v3.

Uses the official Google Calendar REST API:
  https://www.googleapis.com/calendar/v3/

OAuth 2.0 Bearer token from oauth_tokens table.
Supports incremental sync via nextSyncToken.

Usage:
    result = await sync_google_calendar(service, access_token)
"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Any

import httpx
from loguru import logger

CALENDAR_API_BASE = "https://www.googleapis.com/calendar/v3"
TOKEN_URL = "https://oauth2.googleapis.com/token"


async def _refresh_access_token(refresh_token: str) -> dict[str, Any] | None:
    """Get a new access token using the refresh token."""
    client_id = os.environ.get("GOOGLE_CLIENT_ID", "")
    client_secret = os.environ.get("GOOGLE_CLIENT_SECRET", "")

    if not client_id or not client_secret:
        logger.error("Cannot refresh token: GOOGLE_CLIENT_ID or GOOGLE_CLIENT_SECRET missing")
        return None

    async with httpx.AsyncClient() as http:
        resp = await http.post(
            TOKEN_URL,
            data={
                "client_id": client_id,
                "client_secret": client_secret,
                "refresh_token": refresh_token,
                "grant_type": "refresh_token",
            },
        )
        if resp.status_code != 200:
            logger.error(f"Token refresh failed: {resp.status_code} {resp.text}")
            return None
        return resp.json()


async def _list_events(
    access_token: str,
    sync_token: str | None = None,
) -> dict[str, Any]:
    """Fetch events from Google Calendar API v3, handling pagination."""
    headers = {"Authorization": f"Bearer {access_token}"}
    params: dict[str, Any] = {"calendarId": "primary"}

    if sync_token:
        params["syncToken"] = sync_token
    else:
        # Full sync: fetch events from the last 12 months
        from datetime import timedelta
        now = datetime.now(timezone.utc)
        one_year_ago = now - timedelta(days=365)
        params["timeMin"] = one_year_ago.isoformat()
        # Don't set timeMax for full sync — get all future events too

    all_items: list[dict] = []
    next_sync_token: str | None = None
    page_token: str | None = None

    async with httpx.AsyncClient() as http:
        while True:
            if page_token:
                params["pageToken"] = page_token

            resp = await http.get(
                f"{CALENDAR_API_BASE}/calendars/primary/events",
                headers=headers,
                params=params,
            )

            if resp.status_code != 200:
                error_text = resp.text[:500]
                logger.error(
                    f"Google Calendar API returned {resp.status_code}: {error_text}"
                )
                return {
                    "items": [],
                    "nextSyncToken": None,
                    "error": f"API error {resp.status_code}: {error_text}",
                }

            data = resp.json()

            items = data.get("items", [])
            all_items.extend(items)
            logger.info(f"Fetched {len(items)} events (page)")

            next_sync_token = data.get("nextSyncToken")
            page_token = data.get("nextPageToken")
            if not page_token:
                break

    return {
        "items": all_items,
        "nextSyncToken": next_sync_token,
    }


def _parse_event_datetime(
    dt_info: dict[str, str] | None,
    is_all_day: bool = False,
) -> str:
    """Convert Google Calendar datetime info to a naive ISO 8601 string.

    Google returns times like "2026-06-01T14:00:00+08:00" (with timezone offset).
    Dart's DateTime.parse() treats timezone-aware strings as UTC, which causes
    .hour to return the UTC hour instead of local. We strip the offset so Dart
    parses the time as local wall-clock time, matching the user's intent.
    """
    if not dt_info:
        return ""
    if "dateTime" in dt_info:
        dt_str = dt_info["dateTime"]
        try:
            parsed = datetime.fromisoformat(dt_str)
            # Strip timezone → keep wall-clock time (e.g. 14:00 stays 14:00)
            if parsed.tzinfo is not None:
                parsed = parsed.replace(tzinfo=None)
            return parsed.isoformat()
        except (ValueError, TypeError):
            return dt_str
    date_str = dt_info.get("date", "")
    if date_str and is_all_day:
        return f"{date_str}T00:00:00"
    return date_str


async def delete_google_event(
    access_token: str,
    google_event_id: str,
    calendar_id: str = "primary",
) -> dict[str, Any]:
    """Delete a single event from Google Calendar.

    Returns dict with keys: success (bool), error (str|None).
    """
    headers = {"Authorization": f"Bearer {access_token}"}
    url = f"{CALENDAR_API_BASE}/calendars/{calendar_id}/events/{google_event_id}"

    async with httpx.AsyncClient() as http:
        resp = await http.delete(url, headers=headers)
        if resp.status_code == 204:
            logger.info(f"Deleted Google event {google_event_id}")
            return {"success": True, "error": None}
        error_text = resp.text[:500]
        logger.error(
            f"Failed to delete Google event {google_event_id}: "
            f"{resp.status_code} {error_text}"
        )
        return {"success": False, "error": f"API error {resp.status_code}: {error_text}"}


async def update_google_event(
    access_token: str,
    google_event_id: str,
    updates: dict[str, Any],
    calendar_id: str = "primary",
) -> dict[str, Any]:
    """Update a single event on Google Calendar.

    updates may contain: summary, description, start, end, colorId.

    Returns dict with keys: success (bool), error (str|None).
    """
    headers = {"Authorization": f"Bearer {access_token}"}
    url = f"{CALENDAR_API_BASE}/calendars/{calendar_id}/events/{google_event_id}"

    # Build the Google Calendar event body
    body: dict[str, Any] = {}
    if "summary" in updates:
        body["summary"] = updates["summary"]
    if "description" in updates:
        body["description"] = updates["description"]
    if "start" in updates:
        body["start"] = updates["start"]
    if "end" in updates:
        body["end"] = updates["end"]
    if "colorId" in updates and updates["colorId"] is not None:
        body["colorId"] = updates["colorId"]

    if not body:
        return {"success": True, "error": None}

    async with httpx.AsyncClient() as http:
        resp = await http.patch(url, headers=headers, json=body)
        if resp.status_code == 200:
            logger.info(f"Updated Google event {google_event_id}")
            return {"success": True, "error": None}
        error_text = resp.text[:500]
        logger.error(
            f"Failed to update Google event {google_event_id}: "
            f"{resp.status_code} {error_text}"
        )
        return {"success": False, "error": f"API error {resp.status_code}: {error_text}"}


def _map_color_to_google(color: str | None) -> str | None:
    """Map our hex color to a Google Calendar colorId (1-11).

    Google Calendar API uses numbered color IDs, but also supports hex colors
    via the 'extendedProperties' or direct color fields.
    For simplicity, we pass the hex color through extendedProperties
    and use Google's standard color IDs when possible.
    """
    if not color:
        return None
    # Google Calendar v3 supports custom colors via 'color' in event object
    # The API endpoint with ?fields=colorId actually supports custom colors
    # We can use the event's 'colorId' field with custom values.
    # For now, map common colors:
    mapping = {
        "#4285F4": "1",  # Lavender / blue
        "#34A853": "2",  # Sage / green
        "#A142F4": "3",  # Grape / purple
        "#F4511E": "4",  # Tangerine / orange
        "#EA4335": "5",  # Tomato / red
        "#FBBC04": "7",  # Banana / yellow (6 is flamingo)
        "#24C1E0": "6",  # Flamingo (cyan-like)
    }
    return mapping.get(color)


async def sync_google_calendar(
    service,  # CalendarService
    access_token: str,
) -> dict[str, Any]:
    """Full or incremental sync from Google Calendar into local events table.

    Returns a status dict: {synced_count, deleted_count, sync_token, error}.
    """
    from .calendar_service import CalendarService

    result: dict[str, Any] = {
        "synced_count": 0,
        "deleted_count": 0,
        "sync_token": None,
        "error": None,
    }

    try:
        # 1. Check if we have a previous sync token
        sync_state = service.get_sync_state("google")
        sync_token = sync_state.get("next_sync_token") if sync_state else None

        # 2. Fetch events from Google Calendar
        resp = await _list_events(access_token, sync_token=sync_token)

        if resp.get("error"):
            # Try refreshing the token if request failed with auth error
            logger.info("Attempting token refresh...")
            token_data = service.get_oauth_token("google")
            if token_data and token_data.get("refresh_token"):
                new_tokens = await _refresh_access_token(token_data["refresh_token"])
                if new_tokens and new_tokens.get("access_token"):
                    access_token = new_tokens["access_token"]
                    # Save new tokens
                    from datetime import datetime, timezone, timedelta
                    expires_in = new_tokens.get("expires_in", 3600)
                    expiry = (datetime.now(timezone.utc) + timedelta(seconds=expires_in)).isoformat()
                    service.save_oauth_token(
                        "google",
                        access_token=access_token,
                        refresh_token=token_data.get("refresh_token"),
                        token_expiry=expiry,
                    )
                    logger.info("Token refreshed, retrying sync...")
                    resp = await _list_events(access_token, sync_token=sync_token)

        if resp.get("error"):
            result["error"] = resp["error"]
            return result

        items = resp.get("items", [])
        new_sync_token = resp.get("nextSyncToken")

        # 3. Upsert each event
        for item in items:
            ext_id = item.get("id", "")
            if not ext_id:
                continue

            start_info = item.get("start", {})
            end_info = item.get("end", {})
            is_all_day = "date" in start_info

            start_time = _parse_event_datetime(start_info, is_all_day)
            end_time = _parse_event_datetime(end_info, is_all_day)

            service.upsert_google_event(
                external_id=ext_id,
                title=item.get("summary", "(无标题)"),
                description=item.get("description", ""),
                start_time=start_time,
                end_time=end_time,
                is_all_day=is_all_day,
                etag=item.get("etag"),
                recurrence=",".join(item.get("recurrence", [])),
                status=item.get("status", "confirmed"),
                color=item.get("colorId"),
            )

        result["synced_count"] = len(items)

        # 4. If this was a full sync (no sync_token), clean stale events
        if not sync_token and new_sync_token:
            keep_ids = {e.get("id") for e in items if e.get("id")}
            result["deleted_count"] = service.delete_google_events_except(keep_ids)

        # 5. Save new sync token
        if new_sync_token:
            service.update_sync_state("google", sync_token=new_sync_token)
            result["sync_token"] = new_sync_token

        logger.info(
            f"Google sync complete: {result['synced_count']} events, "
            f"{result['deleted_count']} deleted"
        )

    except Exception as exc:
        logger.opt(exception=True).error(f"Google Calendar sync failed: {exc}")
        result["error"] = str(exc)

    return result
