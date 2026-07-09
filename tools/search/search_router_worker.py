#!/usr/bin/env python3
"""Persistent ToyTalk search-router worker.

The Hub uses this tiny local model to decide whether a child question needs
current/live web information.  It intentionally does not answer the question;
it only routes.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any


PROTOCOL_STDOUT = sys.stdout
sys.stdout = sys.stderr


TRAIN_POSITIVE = [
    "Who is the president right now?",
    "Who is the vice president right now?",
    "Who is the VP today?",
    "Who runs America now?",
    "Who is the mayor today?",
    "What is the weather today?",
    "Will it rain tomorrow?",
    "Is it hot outside right now?",
    "Who won the basketball game yesterday?",
    "What was the score last night?",
    "Did the 49ers win today?",
    "What movies are new this week?",
    "Is there a new episode of Paw Patrol?",
    "What is the latest iPad?",
    "How much are Disneyland tickets today?",
    "Is the zoo open tomorrow?",
    "What time does Target close today?",
    "What is happening in the news?",
    "Did the election happen yet?",
    "Who won the election?",
    "Can we go to the park today?",
    "Is the library open right now?",
    "What is the newest toy in stores?",
    "What is the price of bitcoin now?",
    "Who is playing in the Super Bowl this year?",
    "What day is Thanksgiving this year?",
]

TRAIN_NEGATIVE = [
    "How does rain form?",
    "How does weather work?",
    "Why is winter cold?",
    "Why is the sky blue?",
    "What does a president do?",
    "What does a vice president do?",
    "What is a mayor?",
    "How do elections work?",
    "Tell me a puppy joke.",
    "Can you pretend to be a dragon?",
    "Do you like cookies?",
    "What is two plus three?",
    "Count to ten with me.",
    "Why do leaves change color?",
    "How does the moon shine?",
    "What is a dinosaur?",
    "Tell me a bedtime story.",
    "Why do cats purr?",
    "How do airplanes fly?",
    "What is snow?",
    "What is a rainbow?",
    "Can you sing a silly song?",
    "What is sharing?",
    "Why should I brush my teeth?",
    "How does a seed grow?",
]


def _send(payload: dict[str, Any]) -> None:
    PROTOCOL_STDOUT.write(json.dumps(payload, separators=(",", ":")) + "\n")
    PROTOCOL_STDOUT.flush()


class SearchRouter:
    def __init__(self, model_name: str) -> None:
        from sentence_transformers import SentenceTransformer
        from sklearn.linear_model import LogisticRegression

        self.model_name = model_name
        self.model = SentenceTransformer(model_name)
        train_texts = TRAIN_POSITIVE + TRAIN_NEGATIVE
        train_labels = [1] * len(TRAIN_POSITIVE) + [0] * len(TRAIN_NEGATIVE)
        train_embeddings = self.model.encode(train_texts, normalize_embeddings=True)
        self.classifier = LogisticRegression(
            C=1.0,
            class_weight="balanced",
            solver="liblinear",
            random_state=7,
        ).fit(train_embeddings, train_labels)

    def classify(self, text: str) -> dict[str, Any]:
        normalized = " ".join(text.strip().split())
        if not normalized:
            return {
                "ok": True,
                "needs_web_search": False,
                "confidence": 1.0,
                "score": 0.0,
                "reason": "empty_message",
            }
        embedding = self.model.encode([normalized], normalize_embeddings=True)
        score = float(self.classifier.predict_proba(embedding)[0][1])
        if score >= 0.55:
            needs = True
            confidence = min(1.0, 0.5 + ((score - 0.5) * 2.0))
            reason = "current_or_live_information"
        elif score <= 0.45:
            needs = False
            confidence = min(1.0, 0.5 + ((0.5 - score) * 2.0))
            reason = "timeless_or_play_conversation"
        else:
            needs = True
            confidence = 0.5
            reason = "uncertain_needs_search_fails_closed"
        return {
            "ok": True,
            "needs_web_search": needs,
            "confidence": round(confidence, 4),
            "score": round(score, 4),
            "reason": reason,
            "model": self.model_name,
        }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run ToyTalk search-router worker")
    parser.add_argument("--model", default="sentence-transformers/all-MiniLM-L6-v2")
    parser.add_argument("--healthcheck", action="store_true")
    args = parser.parse_args()

    try:
        router = SearchRouter(args.model)
        if args.healthcheck:
            positive = router.classify("Who is the president today?")
            vice_positive = router.classify("Who is the vice president today?")
            negative = router.classify("What does a president do?")
            if (
                not positive["needs_web_search"]
                or not vice_positive["needs_web_search"]
                or negative["needs_web_search"]
            ):
                _send(
                    {
                        "ok": False,
                        "event": "healthcheck_failed",
                        "positive": positive,
                        "vice_positive": vice_positive,
                        "negative": negative,
                    }
                )
                return 2
            _send({"ok": True, "event": "healthcheck_ok", "model": args.model})
            return 0

        _send({"ok": True, "event": "ready", "model": args.model})
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
                command = request.get("command")
                if command == "shutdown":
                    _send({"ok": True, "event": "shutdown"})
                    return 0
                if command != "classify":
                    raise ValueError(f"unsupported command: {command}")
                text = str(request.get("text") or "")
                _send(router.classify(text))
            except Exception as exc:  # pragma: no cover - process boundary
                _send({"ok": False, "error": str(exc)})
    except Exception as exc:  # pragma: no cover - process boundary
        _send({"ok": False, "event": "startup_failed", "error": str(exc)})
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
