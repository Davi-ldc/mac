#!/usr/bin/env python3
"""Writes a made-up workspace at the scale the store has to hold: 5000 users, 300 conversations
(200 channels, 80 DMs, 20 group DMs) and 8 channels of 1000 messages, in the layout of
store/fixture.h. `make memory SCALE=1` and `make bench` read it; it is generated, never committed.

Usage: scale.py <folder>"""
import json
import os
import random
import sys

USERS, CHANNELS, DMS, MPIMS, BUSY, MESSAGES = 5000, 200, 80, 20, 8, 1000
TEAM = "T0SCALE"
START = 1790000000
WORDS = ("plan review ship draft notes sync budget launch design copy test deploy metrics roadmap "
         "invoice schedule feedback sprint backlog release fix sketch call agenda summary").split()


def user_id(n):
    return "U0SC%05d" % n


def write(folder, name, body):
    path = os.path.join(folder, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as out:
        json.dump(dict(ok=True, **body), out)


def user(n, rng):
    first, last = "Person%d" % n, rng.choice(["Silva", "Souza", "Lima", "Costa", "Rocha", "Alves"])
    images = {"image_%d" % size: "https://avatars.example.com/%s-%d.png" % (user_id(n), size) for size in (24, 32, 48, 72, 192, 512)}
    profile = dict(real_name="%s %s" % (first, last), display_name="p%d" % n, first_name=first, last_name=last,
                   title=rng.choice(["Designer", "Engineer", "Teacher", "Finance", ""]), status_text="", status_emoji="",
                   avatar_hash="g%05d" % n, team=TEAM, **images)
    if n % 7 == 0:
        profile.update(status_text="Out sick", status_emoji=":face_with_thermometer:")
    return dict(id=user_id(n), team_id=TEAM, name="p%d" % n, deleted=n % 97 == 0, real_name=profile["real_name"],
                tz="America/Sao_Paulo", tz_offset=-10800, profile=profile, is_bot=False, updated=START,
                presence="active" if n % 3 else "away", locale="en-US")


def text_message(ts, author, rng, mentions):
    words = rng.sample(WORDS, rng.randint(3, 12))
    elements = [{"type": "text", "text": " ".join(words) + " "}]
    if rng.random() < 0.15:
        elements.append({"type": "user", "user_id": rng.choice(mentions)})
    if rng.random() < 0.1:
        elements.append({"type": "emoji", "name": rng.choice(["tada", "eyes", "rocket", "white_check_mark"])})
    if rng.random() < 0.05:
        elements.append({"type": "link", "url": "https://example.com/%d" % rng.randint(1, 999)})
    message = {"type": "message", "user": author, "ts": ts, "text": " ".join(words),
               "client_msg_id": "%08x-0000-4000-8000-%012x" % (rng.getrandbits(32), rng.getrandbits(48)),
               "blocks": [{"type": "rich_text", "block_id": "b%d" % rng.getrandbits(16),
                           "elements": [{"type": "rich_text_section", "elements": elements}]}]}
    if rng.random() < 0.2:
        message["reactions"] = [{"name": name, "users": rng.sample(mentions, k), "count": k}
                                for name, k in ((rng.choice(["+1", "heart", "joy", "pray"]), rng.randint(1, 5)),)]
    if rng.random() < 0.05:
        message.update(thread_ts=ts, reply_count=rng.randint(1, 20), reply_users=rng.sample(mentions, 3), latest_reply=ts)
    return message


def main(folder):
    rng = random.Random(5000)
    me = user_id(0)
    users = [user(n, rng) for n in range(USERS)]
    write(folder, "auth.test.json", dict(url="https://scale.example.com/", team="Scale", user="p0", team_id=TEAM, user_id=me))
    write(folder, "team.info.json", dict(team=dict(id=TEAM, name="Scale", url="https://scale.example.com/", domain="scale",
                                                   icon={"image_88": "https://avatars.example.com/team-88.png"})))
    write(folder, "users.list.json", dict(members=users))
    write(folder, "dnd.teamInfo.json", dict(users={user_id(n): dict(dnd_enabled=True, next_dnd_start_ts=START, next_dnd_end_ts=4102444800)
                                                   for n in range(1, USERS, 50)}))
    write(folder, "emoji.list.json", dict(emoji={"custom%d" % n: "https://emoji.example.com/custom%d.png" % n for n in range(300)}))

    conversations, counts = [], dict(channels=[], ims=[], mpims=[])
    latest = "%d.000100" % (START + 86400 * 30)
    for n in range(CHANNELS):
        conversation_id = "C0SC%04d" % n
        conversations.append(dict(id=conversation_id, name="channel-%d" % n, is_channel=True, is_member=True, is_private=n % 10 == 0,
                                  created=START, is_general=n == 0, num_members=rng.randint(3, USERS),
                                  topic={"value": "Topic %d" % n}, purpose={"value": "Purpose %d" % n}))
        counts["channels"].append(dict(id=conversation_id, last_read=latest, latest=latest, mention_count=n % 11 == 0, has_unreads=n % 4 == 0))
    for n in range(DMS):
        conversation_id = "D0SC%04d" % n
        conversations.append(dict(id=conversation_id, is_im=True, user=user_id(n + 1), is_open=True, created=START, latest=latest))
        counts["ims"].append(dict(id=conversation_id, last_read=latest, latest=latest, mention_count=0, has_unreads=n % 5 == 0))
    for n in range(MPIMS):
        conversation_id = "G0SC%04d" % n
        members = [me] + [user_id(rng.randint(1, USERS - 1)) for _ in range(3)]
        conversations.append(dict(id=conversation_id, is_mpim=True, is_group=True, is_open=True, name="mpdm-" + "--".join(members) + "-1",
                                  members=members, created=START))
        counts["mpims"].append(dict(id=conversation_id, last_read=latest, latest=latest, mention_count=0, has_unreads=False))
    write(folder, "conversations.list.json", dict(channels=conversations))
    write(folder, "client.counts.json", counts)

    channel_ids = [c["id"] for c in conversations if c.get("is_channel")]
    direct_ids = [c["id"] for c in conversations if not c.get("is_channel")]
    sections = [dict(channel_section_id="L0SCSTARS", name="", type="stars", next_channel_section_id="L0SCWORK",
                     channel_ids_page=dict(channel_ids=channel_ids[:5])),
                dict(channel_section_id="L0SCWORK", name="Work", type="standard", emoji="rocket", next_channel_section_id="L0SCCHANNELS",
                     channel_ids_page=dict(channel_ids=channel_ids[5:40])),
                dict(channel_section_id="L0SCCHANNELS", name="", type="channels", next_channel_section_id="L0SCDMS",
                     channel_ids_page=dict(channel_ids=channel_ids[40:])),
                dict(channel_section_id="L0SCDMS", name="", type="direct_messages", next_channel_section_id="",
                     channel_ids_page=dict(channel_ids=direct_ids))]
    write(folder, "users.channelSections.list.json", dict(channel_sections=sections))

    # The busy channels: 1000 messages each, newest first, a few minutes apart.
    for n in range(BUSY):
        members = [user_id(rng.randint(1, USERS - 1)) for _ in range(40)]
        messages = [text_message("%d.%06d" % (START + i * 180, i), rng.choice(members), rng, members) for i in range(MESSAGES)]
        messages.reverse()
        write(folder, "conversations.history/%s.json" % channel_ids[n], dict(messages=messages, has_more=False))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
