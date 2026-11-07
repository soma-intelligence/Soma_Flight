#!/usr/bin/env python3
"""Fill the App Store Connect record of Soma Flight from docs/app-store/listing.md.

Usage (in a venv with pyjwt, cryptography and requests):

    ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=... python -I Scripts/asc/push_listing.py [--dry-run] [--build 202611051540]

The private key is read from ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8.
Optional: ASC_REVIEW_PHONE, ASC_DEMO_USER, ASC_DEMO_PASSWORD for App Review information.

What it sets: categories, content rights, name, subtitle and privacy URL, version copyright,
description, keywords, promotional text, support and marketing URLs, the age rating
questionnaire (all None or No), price Free, App Review contact and notes, the iPhone 6.9 inch
screenshots, and the build. It never submits for review. App Privacy answers have no public
API: fill them in the web page from the table in listing.md.
"""
import argparse
import hashlib
import os
import re
import sys
import time
from pathlib import Path

import jwt
import requests

ROOT = Path(__file__).resolve().parents[2]
LISTING = ROOT / "docs/app-store/listing.md"
SHOTS = ROOT / "docs/app-store/screenshots/iphone-6.9"
API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "me.somalabs.flight"
LOCALE = "en-US"

LIMITS = {"name": 30, "subtitle": 30, "promotionalText": 170, "description": 4000, "keywords": 100}


def listing():
    text = LISTING.read_text()

    def section(title):
        m = re.search(r"^## " + re.escape(title) + r"[^\n]*\n\n(.*?)(?=\n## |\Z)", text, re.S | re.M)
        if not m:
            sys.exit(f"listing.md: section '{title}' missing")
        return m.group(1).strip()

    def field(label):
        m = re.search(r"\*\*" + re.escape(label) + r"\*\*(?: \(\d+\))?: (.+)", text)
        if not m:
            sys.exit(f"listing.md: field '{label}' missing")
        return m.group(1).strip()

    review = section("App Review information")
    notes = review.split("**Notes**:", 1)[1].split("\n- ", 1)[0]
    notes = "\n".join(line.strip() for line in notes.strip().splitlines())
    data = {
        "name": field("Name"),
        "subtitle": field("Subtitle"),
        "copyright": field("Copyright"),
        "privacyPolicyUrl": field("Privacy Policy URL"),
        "supportUrl": field("Support URL"),
        "marketingUrl": field("Marketing URL"),
        "promotionalText": section("Promotional text (170)"),
        "description": section("Description (4000)"),
        "keywords": section("Keywords (100)"),
        "reviewNotes": notes,
    }
    for key, limit in LIMITS.items():
        if len(data[key]) > limit:
            sys.exit(f"{key} is {len(data[key])} characters, limit {limit}")
    if "—" in "".join(data.values()):
        sys.exit("listing.md contains an em dash")
    return data


class ASC:
    def __init__(self, key_id, issuer, dry):
        self.key = (Path.home() / f".appstoreconnect/private_keys/AuthKey_{key_id}.p8").read_text()
        self.key_id, self.issuer, self.dry = key_id, issuer, dry
        self.token, self.exp = None, 0

    def headers(self):
        now = int(time.time())
        if now > self.exp - 60:
            self.exp = now + 1200
            payload = {"iss": self.issuer, "iat": now, "exp": self.exp, "aud": "appstoreconnect-v1"}
            self.token = jwt.encode(payload, self.key, algorithm="ES256", headers={"kid": self.key_id, "typ": "JWT"})
        return {"Authorization": "Bearer " + self.token, "Content-Type": "application/json"}

    def get(self, path, **params):
        r = requests.get(API + path, headers=self.headers(), params=params)
        if not r.ok:
            sys.exit(f"GET {path}: {r.status_code} {r.text[:400]}")
        return r.json()

    def send(self, method, path, body):
        if self.dry and method != "GET":
            print(f"[dry-run] {method} {path}")
            return {"data": {"id": "dry", "attributes": {}}}
        r = requests.request(method, API + path, headers=self.headers(), json=body)
        if not r.ok:
            print(f"!! {method} {path}: {r.status_code} {r.text[:600]}")
            return None
        return r.json() if r.content else {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--build", help="build number to attach (CFBundleVersion)")
    args = ap.parse_args()
    data = listing()
    asc = ASC(os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], args.dry_run)

    app = asc.get("/v1/apps", **{"filter[bundleId]": BUNDLE_ID})["data"][0]
    app_id = app["id"]
    print("app", app_id, app["attributes"]["name"])

    asc.send("PATCH", f"/v1/apps/{app_id}", {"data": {"type": "apps", "id": app_id, "attributes": {
        "contentRightsDeclaration": "USES_THIRD_PARTY_CONTENT"}}})

    # App info: the one still editable (state not READY_FOR_DISTRIBUTION).
    infos = asc.get(f"/v1/apps/{app_id}/appInfos")["data"]
    info = next(i for i in infos if i["attributes"].get("appStoreState") != "READY_FOR_DISTRIBUTION")
    asc.send("PATCH", f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": {
        "primaryCategory": {"data": {"type": "appCategories", "id": "TRAVEL"}},
        "secondaryCategory": {"data": {"type": "appCategories", "id": "NAVIGATION"}}}}})
    for loc in asc.get(f"/v1/appInfos/{info['id']}/appInfoLocalizations")["data"]:
        if loc["attributes"]["locale"] == LOCALE:
            asc.send("PATCH", f"/v1/appInfoLocalizations/{loc['id']}", {"data": {
                "type": "appInfoLocalizations", "id": loc["id"], "attributes": {
                    "name": data["name"], "subtitle": data["subtitle"],
                    "privacyPolicyUrl": data["privacyPolicyUrl"]}}})

    # Age rating: every content descriptor None, every yes/no question No.
    rating = asc.get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration")["data"]
    attrs = {}
    for key, value in rating["attributes"].items():
        if isinstance(value, bool) or key in BOOL_RATINGS:
            attrs[key] = False
        elif isinstance(value, str) or value is None:
            if key in SKIP_RATINGS:
                continue
            attrs[key] = "NONE"
    asc.send("PATCH", f"/v1/ageRatingDeclarations/{rating['id']}", {"data": {
        "type": "ageRatingDeclarations", "id": rating["id"], "attributes": attrs}})

    # Version 1.0 on iOS.
    versions = asc.get(f"/v1/apps/{app_id}/appStoreVersions", **{"filter[platform]": "IOS"})["data"]
    version = next(v for v in versions if v["attributes"]["appStoreState"] in EDITABLE)
    vid = version["id"]
    print("version", version["attributes"]["versionString"], version["attributes"]["appStoreState"])
    asc.send("PATCH", f"/v1/appStoreVersions/{vid}", {"data": {"type": "appStoreVersions", "id": vid, "attributes": {
        "copyright": data["copyright"], "releaseType": "AFTER_APPROVAL"}}})

    vloc = next(l for l in asc.get(f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"]
                if l["attributes"]["locale"] == LOCALE)
    asc.send("PATCH", f"/v1/appStoreVersionLocalizations/{vloc['id']}", {"data": {
        "type": "appStoreVersionLocalizations", "id": vloc["id"], "attributes": {
            k: data[k] for k in ("description", "keywords", "promotionalText", "supportUrl", "marketingUrl")}}})

    review(asc, vid, data)
    price_free(asc, app_id)
    screenshots(asc, vloc["id"])
    if args.build:
        attach_build(asc, app_id, vid, args.build)
    print("done. Not submitted. Fill App Privacy in the web page.")


EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"}
BOOL_RATINGS = {"gambling", "unrestrictedWebAccess", "lootBox", "messagingAndChat", "parentalControls",
                "ageAssurance", "userGeneratedContent", "advertising", "healthOrWellnessTopics",
                "gamblingAndContests", "seventeenPlus"}
SKIP_RATINGS = {"kidsAgeBand", "ageRatingOverride", "ageRatingOverrideV2", "koreaAgeRatingOverride",
                "developerAgeRatingInfoUrl"}


def review(asc, vid, data):
    attrs = {
        "contactFirstName": "Quentin", "contactLastName": "Caron", "contactEmail": "quentin@somalabs.me",
        "contactPhone": os.environ.get("ASC_REVIEW_PHONE", ""), "notes": data["reviewNotes"],
        "demoAccountRequired": True,
        "demoAccountName": os.environ.get("ASC_DEMO_USER", ""),
        "demoAccountPassword": os.environ.get("ASC_DEMO_PASSWORD", ""),
    }
    attrs = {k: v for k, v in attrs.items() if v != ""}
    existing = asc.get(f"/v1/appStoreVersions/{vid}/appStoreReviewDetail").get("data")
    if existing:
        asc.send("PATCH", f"/v1/appStoreReviewDetails/{existing['id']}", {"data": {
            "type": "appStoreReviewDetails", "id": existing["id"], "attributes": attrs}})
    else:
        asc.send("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})


def price_free(asc, app_id):
    points = asc.get(f"/v1/apps/{app_id}/appPricePoints", **{"filter[territory]": "USA", "limit": 200})["data"]
    free = next((p for p in points if float(p["attributes"]["customerPrice"]) == 0), None)
    if not free:
        print("!! no free price point found")
        return
    asc.send("POST", "/v1/appPriceSchedules", {
        "data": {"type": "appPriceSchedules", "relationships": {
            "app": {"data": {"type": "apps", "id": app_id}},
            "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
            "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]}}},
        "included": [{"type": "appPrices", "id": "${free}", "attributes": {"startDate": None},
                      "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}}}]})


def screenshots(asc, vloc_id):
    files = sorted(SHOTS.glob("*.png"))
    if not files:
        print("!! no screenshots in", SHOTS)
        return
    sets = asc.get(f"/v1/appStoreVersionLocalizations/{vloc_id}/appScreenshotSets")["data"]
    shot_set = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == "APP_IPHONE_67"), None)
    if shot_set:
        for old in asc.get(f"/v1/appScreenshotSets/{shot_set['id']}/appScreenshots")["data"]:
            asc.send("DELETE", f"/v1/appScreenshots/{old['id']}", None)
    else:
        shot_set = asc.send("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": "APP_IPHONE_67"}, "relationships": {
                "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": vloc_id}}}}})["data"]
    for f in files:
        blob = f.read_bytes()
        made = asc.send("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots",
            "attributes": {"fileName": f.name, "fileSize": len(blob)}, "relationships": {
                "appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": shot_set["id"]}}}}})
        if not made or asc.dry:
            continue
        shot = made["data"]
        for op in shot["attributes"]["uploadOperations"]:
            part = blob[op["offset"]:op["offset"] + op["length"]]
            hdrs = {h["name"]: h["value"] for h in op["requestHeaders"]}
            requests.request(op["method"], op["url"], headers=hdrs, data=part).raise_for_status()
        asc.send("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(blob).hexdigest()}}})
        print("screenshot", f.name)


def attach_build(asc, app_id, vid, number):
    builds = asc.get("/v1/builds", **{"filter[app]": app_id, "filter[version]": number})["data"]
    if not builds:
        print("!! build", number, "not found (still processing?)")
        return
    b = builds[0]
    print("build", number, b["attributes"]["processingState"])
    asc.send("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build", {"data": {"type": "builds", "id": b["id"]}})


if __name__ == "__main__":
    main()
