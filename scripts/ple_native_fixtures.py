#!/usr/bin/env python3
"""Pinned phase-3 quality-screen fixtures: identical prompts, order and seeds
for both arms (IQ4 production pack vs BF16 PLE candidate pack).

Every generator is deterministic: needles vary only with the replicate index
(so replicate 2 re-prefills fresh text) but are byte-identical across arms
within a replicate; knowledge/tools/MTP/determinism fixtures are constants.

No fixture was tuned against either arm's outputs: items were written from
general knowledge and the grading rules fixed before the first arm ran.
"""
from __future__ import annotations

import random

# ---------------------------------------------------------------------------
# Needle-in-a-haystack battery. Three depths x NEEDLE_PER_DEPTH items.
# ---------------------------------------------------------------------------

NEEDLE_DEPTHS = (2048, 8192, 32768)
NEEDLE_PER_DEPTH = 8
# Replicate 2 adds a deeper 65,536-token band (4 items): replicate 1 showed
# the three standard bands at ceiling (100% both arms), so the deeper band
# probes where errors begin. Applied identically to both arms.
NEEDLE_DEPTHS_R2 = (2048, 8192, 32768, 65536)
NEEDLE_PER_DEPTH_R2 = {2048: 8, 8192: 8, 32768: 8, 65536: 4}
NEEDLE_NAMES = (
    "the archivist", "the cartographer", "the auditor", "the librarian",
    "the surveyor", "the curator", "the registrar", "the archivist",
)
NEEDLE_ADJS = (
    "western", "northern", "coastal", "inland", "upland", "eastern",
    "southern", "rural",
)

_FILLER_SUBJECTS = (
    "the survey team", "the harbour office", "the regional council",
    "the canal commission", "the weather station", "the rail operator",
    "the water board", "the mapping agency", "the grain exchange",
    "the ferry company", "the customs office", "the mining bureau",
    "the forestry wardens", "the bridge authority", "the postal service",
    "the telegraph office",
)
_FILLER_VERBS = (
    "filed its quarterly summary", "recorded the rainfall totals",
    "published the freight schedule", "revised the depth charts",
    "catalogued the incoming ledgers", "adjusted the tariffs",
    "summarised the maintenance logs", "tabulated the cargo weights",
    "annotated the boundary sketches", "archived the correspondence",
    "indexed the timber yields", "transcribed the meeting minutes",
    "reviewed the signal reports", "updated the tide tables",
    "collated the survey notes", "appraised the land parcels",
)
_FILLER_TAILS = (
    "for the spring season", "across the northern districts",
    "before the autumn review", "following the spring inspection",
    "under the revised convention", "after the winter recess",
    "in preparation for the audit", "as part of the annual settlement",
    "for the inland depots", "beside the eastern anchorage",
    "under the coastal charter", "for the upland parishes",
    "during the quiet quarter", "ahead of the harvest",
    "for the western registry", "beyond the second milestone",
)

_SENTINEL = "0xPLE-PHASE3"


def _filler_text(target_chars: int, seed: int) -> str:
    rng = random.Random(seed)
    out: list[str] = []
    n = 0
    while n < target_chars:
        s = (f"{_SENTINEL} Document note {len(out) + 1}: "
             f"{rng.choice(_FILLER_SUBJECTS)} {rng.choice(_FILLER_VERBS)} "
             f"{rng.choice(_FILLER_TAILS)}. "
             f"The entry was countersigned by clerk {rng.randrange(100, 999)} "
             f"on day {rng.randrange(1, 28)} of the month.\n")
        out.append(s)
        n += len(s)
    return "".join(out)


def needle_fixtures(replicate: int) -> list[dict]:
    """One needle item per (depth, index); nonce differs per replicate."""
    if replicate >= 2:
        depths, per_depth = NEEDLE_DEPTHS_R2, NEEDLE_PER_DEPTH_R2
    else:
        depths = NEEDLE_DEPTHS
        per_depth = {d: NEEDLE_PER_DEPTH for d in NEEDLE_DEPTHS}
    items = []
    for depth in depths:
        for i in range(per_depth[depth]):
            rng = random.Random(f"ple-p3-needle-{replicate}-{depth}-{i}")
            code = f"{rng.randrange(1000000, 9999999)}"
            name = NEEDLE_NAMES[i % len(NEEDLE_NAMES)]
            adj = NEEDLE_ADJS[i % len(NEEDLE_ADJS)]
            nonce = f"{replicate:02d}{depth:05d}{i:02d}"
            body = _filler_text(int(depth * 4.15), rng.randrange(1 << 30))
            needle = (f"Private record {nonce}: {name} noted the seven-digit "
                      f"access code for the {adj} archive; the code is "
                      f"{code}. This note is the only place the code appears.")
            cut = int(depth * 4.15)
            cut = min(cut, max(0, len(body) - 200))
            prompt = (body[:cut] + "\n" + needle + "\n" + body[cut:]
                      + "\n\n"
                      + f"What seven-digit access code did {name} note for "
                      f"the {adj} archive? Reply with the seven digits only.")
            items.append({
                "id": f"needle-d{depth}-i{i}",
                "depth": depth, "index": i, "replicate": replicate,
                "nonce": nonce, "code": code, "name": name, "adj": adj,
                "prompt": prompt,
                "expect_substring": code,
            })
    return items


# ---------------------------------------------------------------------------
# Knowledge panel (primitive-ai-comparable axis: short factual questions,
# deterministic exact-answer grading).
# ---------------------------------------------------------------------------

KNOWLEDGE = (
    ("What is the capital of Australia?", "Canberra"),
    ("What is the capital of Canada?", "Ottawa"),
    ("What is the capital of Brazil?", "Brasilia"),
    ("What is the capital of Turkey?", "Ankara"),
    ("What is the capital of Switzerland?", "Bern"),
    ("What is the capital of Nigeria?", "Abuja"),
    ("What is the capital of Vietnam?", "Hanoi"),
    ("What is the capital of New Zealand?", "Wellington"),
    ("What chemical element has the symbol Fe?", "iron"),
    ("What chemical element has the symbol K?", "potassium"),
    ("What chemical element has the symbol Pb?", "lead"),
    ("What chemical element has the symbol Sn?", "tin"),
    ("What chemical element has atomic number 79?", "gold"),
    ("What gas makes up about 78 percent of Earth's atmosphere?", "nitrogen"),
    ("How many bones are in the adult human body?", "206"),
    ("What is the largest organ of the human body?", "skin"),
    ("What is the hardest natural substance on Earth?", "diamond"),
    ("What is the most abundant element in the universe?", "hydrogen"),
    ("In what year did the Berlin Wall fall?", "1989"),
    ("In what year did World War I begin?", "1914"),
    ("In what year did the Titanic sink?", "1912"),
    ("Who was the first person to walk on the Moon?", "Armstrong"),
    ("Which country launched the first artificial satellite?", "Soviet"),
    ("In what year did the French Revolution begin?", "1789"),
    ("Who wrote the play Hamlet?", "Shakespeare"),
    ("Who wrote the novel Pride and Prejudice?", "Austen"),
    ("Who wrote the epic poem the Odyssey?", "Homer"),
    ("Who wrote One Hundred Years of Solitude?", "Garcia"),
    ("What is the square root of 144?", "12"),
    ("What is 17 multiplied by 13?", "221"),
    ("What is the value of pi rounded to four decimal places?", "3.1416"),
    ("How many degrees are in the interior angles of a triangle?", "180"),
    ("What is the smallest prime number greater than 100?", "101"),
    ("What does HTTP stand for?", "HyperText Transfer Protocol"),
    ("What does CPU stand for?", "central processing unit"),
    ("Who is credited with creating the C programming language?", "Ritchie"),
    ("What does SQL stand for?", "Structured Query Language"),
    ("What company developed the CUDA parallel computing platform?", "NVIDIA"),
    ("What is the name of the Linux kernel's default shell on Ubuntu?", "bash"),
    ("What protocol translates domain names to IP addresses?", "DNS"),
    ("What is the longest river in Africa?", "Nile"),
    ("What is the largest ocean on Earth?", "Pacific"),
    ("What is the highest mountain above sea level?", "Everest"),
    ("What is the largest desert on Earth?", "Antarctic"),
    ("Which planet has the most moons discovered?", "Saturn"),
    ("Which planet is known as the Red Planet?", "Mars"),
    ("What force keeps planets in orbit around the Sun?", "gravity"),
    ("What is the speed of light in a vacuum, in km per second?", "299792"),
    ("What is the largest country by land area?", "Russia"),
    ("Through which country does the Amazon River primarily flow?", "Brazil"),
    ("What is the currency of Japan?", "yen"),
    ("What is the currency of the United Kingdom?", "pound"),
    ("How many continents are there?", "seven"),
    ("What language has the most native speakers?", "Chinese"),
    ("What is the study of earthquakes called?", "seismology"),
    ("What blood type is known as the universal donor?", "O negative"),
    ("What vaccine did Edward Jenner pioneer?", "smallpox"),
    ("Who proposed the theory of general relativity?", "Einstein"),
    ("Who developed the periodic table's modern arrangement?", "Mendeleev"),
    ("What particle has a negative electric charge?", "electron"),
    ("What is the powerhouse of the cell?", "mitochondria"),
)


def knowledge_fixtures() -> list[dict]:
    return [
        {"id": f"know-{i:02d}", "index": i, "question": q, "answer": a}
        for i, (q, a) in enumerate(KNOWLEDGE)
    ]


# Knowledge subset asked with thinking enabled (primitive-ai ran their panel
# with thinking on); fixed items, first of each block of four.
KNOWLEDGE_THINK_INDICES = tuple(i for i in range(0, 64, 4) if i < 61)[:16]


def knowledge_think_fixtures() -> list[dict]:
    return [
        {**KNOWLEDGE_FIXTURE_CACHE[i], "id": f"knowthink-{i:02d}"}
        for i in KNOWLEDGE_THINK_INDICES
    ]


KNOWLEDGE_FIXTURE_CACHE = knowledge_fixtures()


# ---------------------------------------------------------------------------
# Tool-calling panel (primitive-ai-comparable axis: protocol correctness).
# ---------------------------------------------------------------------------

def _tool(name: str, desc: str, props: dict, required: tuple) -> dict:
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": desc,
            "parameters": {
                "type": "object",
                "properties": props,
                "required": list(required),
            },
        },
    }


_STR = {"type": "string"}
_NUM = {"type": "number"}
_DATE = {"type": "string", "description": "ISO date, YYYY-MM-DD"}

TOOL_CASES = (
    # (tools, user message, expected calls [(name, args-dict)])
    (
        [_tool("get_weather", "Current weather for a city",
               {"city": _STR, "units": {"type": "string", "enum": ["metric", "imperial"]}},
               ("city",))],
        "What is the weather in Lisbon right now? Use metric units.",
        [("get_weather", {"city": "Lisbon", "units": "metric"})],
    ),
    (
        [_tool("get_weather", "Current weather for a city", {"city": _STR}, ("city",))],
        "Is it raining in Oslo?",
        [("get_weather", {"city": "Oslo"})],
    ),
    (
        [_tool("book_meeting", "Book a meeting room",
               {"room": _STR, "date": _DATE, "start": _STR, "minutes": _NUM},
               ("room", "date", "start", "minutes"))],
        "Book the Atlas room on 12 March 2026 at 14:00 for 45 minutes.",
        [("book_meeting", {"room": "Atlas", "date": "2026-03-12", "start": "14:00", "minutes": 45})],
    ),
    (
        [_tool("send_email", "Send an email",
               {"to": _STR, "subject": _STR, "body": _STR}, ("to", "subject", "body"))],
        "Email dana@acme.example with subject 'Invoice attached' and body 'Please find the invoice attached.'",
        [("send_email", {"to": "dana@acme.example", "subject": "Invoice attached",
                         "body": "Please find the invoice attached."})],
    ),
    (
        [_tool("convert_currency", "Convert between currencies",
               {"amount": _NUM, "from": _STR, "to": _STR}, ("amount", "from", "to"))],
        "Convert 250 US dollars to Japanese yen.",
        [("convert_currency", {"amount": 250, "from": "USD", "to": "JPY"})],
    ),
    (
        [_tool("search_docs", "Search internal documentation",
               {"query": _STR, "limit": _NUM}, ("query",))],
        "Search the docs for 'token bucket rate limit' and return at most 5 hits.",
        [("search_docs", {"query": "token bucket rate limit", "limit": 5})],
    ),
    (
        [_tool("create_task", "Create a tracking task",
               {"title": _STR, "priority": {"type": "string", "enum": ["low", "normal", "high"]}},
               ("title",))],
        "Create a task titled 'Rotate the database credentials' with high priority.",
        [("create_task", {"title": "Rotate the database credentials", "priority": "high"})],
    ),
    (
        [_tool("lookup_order", "Look up an order by number", {"order_id": _STR}, ("order_id",))],
        "Where is order A77X129?",
        [("lookup_order", {"order_id": "A77X129"})],
    ),
    (
        [_tool("set_thermostat", "Set a thermostat",
               {"room": _STR, "celsius": _NUM}, ("room", "celsius"))],
        "Set the study thermostat to 21.5 degrees.",
        [("set_thermostat", {"room": "study", "celsius": 21.5})],
    ),
    (
        [_tool("get_flight", "Flight status by number", {"flight": _STR}, ("flight",))],
        "What's the status of flight LH 401?",
        [("get_flight", {"flight": "LH401"})],
    ),
    (
        [_tool("run_query", "Run a read-only SQL query", {"sql": _STR}, ("sql",))],
        "How many users signed up last week? Table users, column created_at. Use count(*).",
        [("run_query", {"sql": "SELECT count(*) FROM users WHERE created_at >= date('now', '-7 days')"})],
        "loose_sql",
    ),
    (
        [_tool("file_read", "Read a file from the workspace", {"path": _STR}, ("path",))],
        "Read the file notes/2026-04-01.md.",
        [("file_read", {"path": "notes/2026-04-01.md"})],
    ),
    (
        [_tool("list_dir", "List a directory", {"path": _STR}, ("path",))],
        "List the contents of the directory src/kernel.",
        [("list_dir", {"path": "src/kernel"})],
    ),
    (
        [_tool("get_stock", "Latest stock quote", {"symbol": _STR}, ("symbol",))],
        "What is the latest price for AAPL?",
        [("get_stock", {"symbol": "AAPL"})],
    ),
    (
        [_tool("translate", "Translate text",
               {"text": _STR, "target": _STR}, ("text", "target"))],
        "Translate 'Good morning, the meeting is at nine' into Spanish.",
        [("translate", {"text": "Good morning, the meeting is at nine", "target": "Spanish"})],
    ),
    (
        [_tool("get_timezone", "Timezone info for a city", {"city": _STR}, ("city",))],
        "What timezone is Reykjavik in?",
        [("get_timezone", {"city": "Reykjavik"})],
    ),
    (
        [_tool("add_contact", "Add a contact",
               {"name": _STR, "email": _STR, "phone": _STR}, ("name",))],
        "Add Marta Vidal with email m.vidal@orion.example and phone +34 611 220 145.",
        [("add_contact", {"name": "Marta Vidal", "email": "m.vidal@orion.example",
                          "phone": "+34 611 220 145"})],
    ),
    (
        [_tool("schedule_backup", "Schedule a backup job",
               {"volume": _STR, "hour": _NUM, "day": _STR}, ("volume", "hour"))],
        "Schedule the backups volume to run at 02:00 every Sunday.",
        [("schedule_backup", {"volume": "backups", "hour": 2, "day": "Sunday"})],
    ),
    (
        [_tool("get_movie", "Movie details by title", {"title": _STR}, ("title",))],
        "Give me details about the film Alien.",
        [("get_movie", {"title": "Alien"})],
    ),
    (
        [_tool("recipe_search", "Search recipes",
               {"ingredient": _STR, "diet": {"type": "string", "enum": ["any", "vegan", "vegetarian"]}},
               ("ingredient",))],
        "Find recipes using aubergine, vegan only.",
        [("recipe_search", {"ingredient": "aubergine", "diet": "vegan"})],
    ),
    (
        [_tool("create_ticket", "Create a support ticket",
               {"summary": _STR, "severity": {"type": "string", "enum": ["S1", "S2", "S3"]}},
               ("summary", "severity"))],
        "Open a ticket: 'Checkout page returns 500' as S1.",
        [("create_ticket", {"summary": "Checkout page returns 500", "severity": "S1"})],
    ),
    (
        [_tool("get_route", "Driving route between two places",
               {"from": _STR, "to": _STR}, ("from", "to"))],
        "Give me a route from Munich to Verona.",
        [("get_route", {"from": "Munich", "to": "Verona"})],
    ),
    (
        [_tool("get_elevator", "Elevator status in a building",
               {"building": _STR, "elevator": _STR}, ("building",))],
        "Is the freight elevator in Building 7 currently in service?",
        [("get_elevator", {"building": "Building 7", "elevator": "freight"})],
    ),
    (
        [_tool("get_weather", "Current weather for a city", {"city": _STR}, ("city",)),
         _tool("get_news", "Latest headlines for a topic", {"topic": _STR}, ("topic",))],
        "What's the weather in Nairobi, and any news about railways there?",
        [("get_weather", {"city": "Nairobi"}), ("get_news", {"topic": "railways"})],
        "parallel",
    ),
    (
        [_tool("get_weather", "Current weather for a city", {"city": _STR}, ("city",)),
         _tool("get_news", "Latest headlines for a topic", {"topic": _STR}, ("topic",))],
        "Check the weather in Helsinki and also the latest news about ferries.",
        [("get_weather", {"city": "Helsinki"}), ("get_news", {"topic": "ferries"})],
        "parallel",
    ),
    (
        [_tool("get_weather", "Current weather for a city", {"city": _STR}, ("city",)),
         _tool("get_news", "Latest headlines for a topic", {"topic": _STR}, ("topic",))],
        "Weather in Osaka, please. No news needed.",
        [("get_weather", {"city": "Osaka"})],
    ),
    (
        [_tool("get_calendar", "Free-busy calendar lookup",
               {"person": _STR, "date": _DATE}, ("person", "date"))],
        "Is Ravi Patel free on 2026-05-04?",
        [("get_calendar", {"person": "Ravi Patel", "date": "2026-05-04"})],
    ),
    (
        [_tool("get_parking", "Parking availability at a garage", {"garage": _STR}, ("garage",))],
        "Any spaces left in the Bell Street garage?",
        [("get_parking", {"garage": "Bell Street"})],
    ),
    (
        [_tool("log_event", "Append an event to the run log",
               {"event": _STR, "level": {"type": "string", "enum": ["info", "warn", "error"]}},
               ("event", "level"))],
        "Log an info event: 'cache warmed successfully'.",
        [("log_event", {"event": "cache warmed successfully", "level": "info"})],
    ),
    (
        [_tool("get_podcast", "Podcast episode lookup", {"show": _STR, "episode": _NUM},
               ("show",))],
        "Find episode 42 of the show Signal Path.",
        [("get_podcast", {"show": "Signal Path", "episode": 42})],
    ),
    (
        [_tool("grant_access", "Grant repository access",
               {"user": _STR, "repo": _STR, "role": {"type": "string", "enum": ["read", "write", "admin"]}},
               ("user", "repo", "role"))],
        "Give user kklimes write access to the repo metrics-agent.",
        [("grant_access", {"user": "kklimes", "repo": "metrics-agent", "role": "write"})],
    ),
    (
        [_tool("get_train", "Next train between stations", {"from": _STR, "to": _STR},
               ("from", "to"))],
        "When is the next train from Utrecht to Amersfoort?",
        [("get_train", {"from": "Utrecht", "to": "Amersfoort"})],
    ),
    (
        [_tool("unit_convert", "Convert between units",
               {"value": _NUM, "from": _STR, "to": _STR}, ("value", "from", "to"))],
        "Convert 26 miles to kilometres.",
        [("unit_convert", {"value": 26, "from": "miles", "to": "kilometres"})],
    ),
    (
        [_tool("get_product", "Product lookup by SKU", {"sku": _STR}, ("sku",))],
        "Look up SKU BT-4471-Q.",
        [("get_product", {"sku": "BT-4471-Q"})],
    ),
    (
        [_tool("post_comment", "Comment on an issue",
               {"issue": _NUM, "body": _STR}, ("issue", "body"))],
        "Comment 'Reproduced on the staging cluster' on issue 3312.",
        [("post_comment", {"issue": 3312, "body": "Reproduced on the staging cluster"})],
    ),
    (
        [_tool("get_sunrise", "Sunrise time for a city and date",
               {"city": _STR, "date": _DATE}, ("city",))],
        "When is sunrise in Stockholm on 21 June 2026?",
        [("get_sunrise", {"city": "Stockholm", "date": "2026-06-21"})],
    ),
    (
        [_tool("allocate_ip", "Allocate an IP address in a subnet",
               {"subnet": _STR, "count": _NUM}, ("subnet",))],
        "Allocate one address in subnet 10.44.9.0/24.",
        [("allocate_ip", {"subnet": "10.44.9.0/24", "count": 1})],
    ),
    (
        [_tool("get_lyrics", "Song lyric search", {"title": _STR, "artist": _STR},
               ("title",))],
        "Find the lyrics of the song Fast Car by Tracy Chapman.",
        [("get_lyrics", {"title": "Fast Car", "artist": "Tracy Chapman"})],
    ),
    (
        [_tool("get_weather", "Current weather for a city", {"city": _STR}, ("city",)),
         _tool("book_meeting", "Book a meeting room",
               {"room": _STR, "date": _DATE, "start": _STR, "minutes": _NUM},
               ("room", "date", "start", "minutes"))],
        "Book room Vega on 2 June 2026 at 09:30 for 30 minutes; also check the weather in Porto.",
        [("book_meeting", {"room": "Vega", "date": "2026-06-02", "start": "09:30", "minutes": 30}),
         ("get_weather", {"city": "Porto"})],
        "parallel",
    ),
    (
        [_tool("deploy_service", "Deploy a service version",
               {"service": _STR,
                "spec": {"type": "object",
                         "properties": {"version": _STR, "replicas": _NUM},
                         "required": ["version", "replicas"]},
                "dry_run": {"type": "boolean"}},
               ("service", "spec"))],
        "Deploy the payments service with spec version 2.4.1 and 3 replicas; "
        "do a dry run.",
        [("deploy_service", {"service": "payments",
                             "spec": {"version": "2.4.1", "replicas": 3},
                             "dry_run": True})],
    ),
)


def tool_fixtures() -> list[dict]:
    items = []
    for i, case in enumerate(TOOL_CASES):
        tools, user, expect = case[0], case[1], case[2]
        mode = case[3] if len(case) > 3 else "single"
        items.append({
            "id": f"tool-{i:02d}", "index": i, "tools": tools,
            "user": user, "expect": expect, "mode": mode,
        })
    return items


# ---------------------------------------------------------------------------
# MTP acceptance workload: fixed 8 prompts, decode-heavy, greedy.
# ---------------------------------------------------------------------------

MTP_PROMPTS = (
    "Explain clearly, in about two hundred words, why the sky is blue during "
    "the day and red at sunset.",
    "Write a short technical summary of how a token bucket rate limiter "
    "works, including the refill and burst parameters.",
    "Summarise the plot of Shakespeare's Hamlet in two hundred words.",
    "Describe how a hash table handles collisions, covering chaining and "
    "open addressing, in about two hundred words.",
    "Write a Python function that returns the n-th Fibonacci number using "
    "memoisation, then explain its complexity.",
    "Explain the difference between TCP and UDP, and when each is the right "
    "choice, in about two hundred words.",
    "List and briefly explain five common sorting algorithms and their "
    "average time complexities.",
    "Explain what a B-tree is, why databases use it for indexes, and how it "
    "differs from a binary search tree.",
)


def mtp_fixtures() -> list[dict]:
    return [
        {"id": f"mtp-{i:02d}", "index": i, "prompt": p}
        for i, p in enumerate(MTP_PROMPTS)
    ]


# ---------------------------------------------------------------------------
# Greedy-determinism fixtures: 4 prompts, each sent twice per session and
# again in the other session (identical bodies).
# ---------------------------------------------------------------------------

DET_PROMPTS = (
    "Name the five most populous countries in the world in order, with one "
    "line of context each.",
    "Write a haiku about a lighthouse, then explain the imagery in one "
    "sentence.",
    "Explain in five numbered steps how to make espresso with a moka pot.",
    "What is the difference between weathering and erosion? Answer in two "
    "sentences.",
)


def determinism_fixtures() -> list[dict]:
    return [
        {"id": f"det-{i:02d}", "index": i, "prompt": p}
        for i, p in enumerate(DET_PROMPTS)
    ]


if __name__ == "__main__":
    n = needle_fixtures(1)
    print(f"needles: {len(n)}; prompt chars: "
          f"{min(len(x['prompt']) for x in n)}..{max(len(x['prompt']) for x in n)}")
    print(f"knowledge: {len(knowledge_fixtures())} "
          f"(think subset {len(knowledge_think_fixtures())})")
    print(f"tools: {len(tool_fixtures())} mtp: {len(mtp_fixtures())} "
          f"det: {len(determinism_fixtures())}")
    print("sample needle prompt head:", n[0]["prompt"][:160].replace("\n", " | "))
