#!/usr/bin/env python3
import json
import re
import sys
import urllib.error
import urllib.request

# Define exclusion keywords and the features they correspond to
EXCLUSIONS = {
    r"\bzcrx\b|\bzc_rx\b": "zcrx (zero-copy RX)",
    r"\bnapi\b": "NAPI busy polling",
    r"\bfutex\b": "FUTEX operations",
    r"\bwaitid\b": "WAITID operations",
    r"\bmsg_ring\b": "MSG_RING operations",
    r"\bpbuf_ring\b": "PBUF_RING incremental buffers",
    r"\bublk\b": "ublk driver",
    r"\bsqe128\b": "128-byte SQE (SQE128/SQE_MIXED)",
    r"\bfuse\b": "libfuse / FUSE daemon integration",
}


def fetch_cves():
    url = "https://services.nvd.nist.gov/rest/json/cves/2.0?keywordSearch=io_uring"
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) TalynCVEBot/1.0"
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.URLError as e:
        print(f"Error fetching CVEs from NVD: {e}", file=sys.stderr)
        return None


def analyze_cve(cve_id, description):
    desc_lower = description.lower()
    for pattern, feature in EXCLUSIONS.items():
        if re.search(pattern, desc_lower):
            return False, f"Not applicable (uses {feature})"

    # Check if it mentions features we do use
    applicable_keywords = [
        "read",
        "write",
        "poll",
        "connect",
        "accept",
        "recv",
        "send",
        "timeout",
        "cancel",
        "teardown",
        "setup",
    ]
    matched = [kw for kw in applicable_keywords if kw in desc_lower]
    if matched:
        return True, f"Potentially applicable (mentions: {', '.join(matched)})"

    return True, "Potentially applicable (general io_uring context)"


def main():
    print("Fetching recent io_uring CVEs from NVD...")
    data = fetch_cves()
    if not data or "vulnerabilities" not in data:
        print("No CVE data retrieved.")
        sys.exit(1)

    vulnerabilities = data["vulnerabilities"]
    print(f"Retrieved {len(vulnerabilities)} vulnerabilities.\n")

    print("| CVE ID | Status | Reason | Description Summary |")
    print("| :--- | :--- | :--- | :--- |")

    for item in vulnerabilities:
        cve = item.get("cve", {})
        cve_id = cve.get("id", "Unknown")
        descriptions = cve.get("descriptions", [])

        # Get English description
        desc_text = ""
        for desc in descriptions:
            if desc.get("lang") == "en":
                desc_text = desc.get("value", "")
                break

        if not desc_text:
            continue

        applicable, reason = analyze_cve(cve_id, desc_text)
        status = "⚠️ POTENTIALLY APPLICABLE" if applicable else "✅ NOT APPLICABLE"

        # Clean description for table
        summary = desc_text.replace("\n", " ").strip()
        if len(summary) > 100:
            summary = summary[:97] + "..."

        print(f"| {cve_id} | {status} | {reason} | {summary} |")


if __name__ == "__main__":
    main()
