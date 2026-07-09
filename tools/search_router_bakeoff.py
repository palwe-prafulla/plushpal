#!/usr/bin/env python3
"""Bake off small local models for ToyTalk current-info routing.

This script intentionally writes results outside the repository by default.
It evaluates whether a small model can decide if a child utterance needs
current/live web data versus ordinary timeless knowledge or play.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional


@dataclass(frozen=True)
class Example:
    text: str
    needs_search: bool
    category: str


EXAMPLES: List[Example] = [
    # Current/live/recent data expected: needs search.
    Example("Who is the president of America today?", True, "current_public_official"),
    Example("Is it going to rain tomorrow in San Jose?", True, "weather_forecast"),
    Example("Did Bluey make a new episode this week?", True, "new_release"),
    Example("Who won the Warriors game last night?", True, "sports_result"),
    Example("What is the newest Disney movie in theaters right now?", True, "current_entertainment"),
    Example("How much does a ticket to Disneyland cost today?", True, "current_price"),
    Example("Is there school tomorrow in Cupertino?", True, "schedule/local_status"),
    Example("What is the latest iPhone called?", True, "latest_product"),
    # Timeless/general/play expected: no search.
    Example("How does rain form?", False, "timeless_science"),
    Example("How does winter weather work?", False, "timeless_science"),
    Example("What does a president do?", False, "timeless_civics"),
    Example("Why do leaves change color in fall?", False, "timeless_science"),
    Example("Tell me a funny puppy joke.", False, "play"),
    Example("What is two plus three?", False, "math"),
    Example("Buddy, do you like cookies?", False, "pretend_play"),
    Example("Why is the moon sometimes bright?", False, "timeless_science"),
]


ZERO_SHOT_LABELS = [
    "requires current, live, recent, or internet information",
    "can be answered with timeless general knowledge or pretend play",
]

TRAIN_POSITIVE = [
    "Who is the president right now?",
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

EMBEDDING_POSITIVE_PROTOTYPES = [
    "The question asks for current, live, recent, or internet information.",
    "The question asks about today's weather, latest news, sports scores, current prices, schedules, elections, public officials, or new releases.",
    "The answer may change depending on the current date or location.",
]

EMBEDDING_NEGATIVE_PROTOTYPES = [
    "The question can be answered with timeless general knowledge.",
    "The message is pretend play, personal conversation, a joke request, simple math, or a stable explanation.",
    "The answer does not depend on today's date, recent events, live weather, or internet search.",
]


def model_dir_size_mb(cache_dir: Path, model_name: str) -> float:
    """Best-effort cache size estimate for a Hugging Face model."""

    safe_name = "models--" + model_name.replace("/", "--")
    totals = []
    for base in [
        cache_dir / "hub" / safe_name,
        cache_dir / safe_name,
        Path.home() / ".cache" / "huggingface" / "hub" / safe_name,
    ]:
        total = 0
        if base.exists():
            for path in base.rglob("*"):
                if path.is_file():
                    try:
                        total += os.lstat(path).st_size
                    except OSError:
                        pass
            totals.append(total)
    return round((max(totals) if totals else 0) / 1024 / 1024, 1)


def eval_zero_shot(model_name: str, cache_dir: Path) -> Dict[str, Any]:
    from transformers import pipeline

    started = time.perf_counter()
    clf = pipeline(
        "zero-shot-classification",
        model=model_name,
        tokenizer=model_name,
        device=-1,
        cache_dir=str(cache_dir),
    )
    load_ms = int((time.perf_counter() - started) * 1000)

    rows = []
    latencies = []
    for item in EXAMPLES:
        t0 = time.perf_counter()
        out = clf(
            item.text,
            candidate_labels=ZERO_SHOT_LABELS,
            hypothesis_template="This child message {}.",
            multi_label=False,
        )
        elapsed_ms = int((time.perf_counter() - t0) * 1000)
        latencies.append(elapsed_ms)

        labels = out["labels"]
        scores = out["scores"]
        score_by_label = dict(zip(labels, scores))
        positive_score = float(score_by_label[ZERO_SHOT_LABELS[0]])
        negative_score = float(score_by_label[ZERO_SHOT_LABELS[1]])
        predicted = positive_score >= negative_score
        rows.append(
            {
                "text": item.text,
                "category": item.category,
                "expected_needs_search": item.needs_search,
                "predicted_needs_search": predicted,
                "correct": predicted == item.needs_search,
                "positive_score": round(positive_score, 4),
                "negative_score": round(negative_score, 4),
                "latency_ms": elapsed_ms,
            }
        )

    return summarize(model_name, "zero_shot", load_ms, rows, latencies, cache_dir)


def eval_embeddings(model_name: str, cache_dir: Path) -> Dict[str, Any]:
    import numpy as np
    from sentence_transformers import SentenceTransformer

    started = time.perf_counter()
    model = SentenceTransformer(model_name, cache_folder=str(cache_dir))
    load_ms = int((time.perf_counter() - started) * 1000)

    pos_emb = model.encode(EMBEDDING_POSITIVE_PROTOTYPES, normalize_embeddings=True)
    neg_emb = model.encode(EMBEDDING_NEGATIVE_PROTOTYPES, normalize_embeddings=True)

    rows = []
    latencies = []
    for item in EXAMPLES:
        t0 = time.perf_counter()
        emb = model.encode([item.text], normalize_embeddings=True)[0]
        pos_score = float(np.max(pos_emb @ emb))
        neg_score = float(np.max(neg_emb @ emb))
        elapsed_ms = int((time.perf_counter() - t0) * 1000)
        latencies.append(elapsed_ms)

        predicted = pos_score >= neg_score
        rows.append(
            {
                "text": item.text,
                "category": item.category,
                "expected_needs_search": item.needs_search,
                "predicted_needs_search": predicted,
                "correct": predicted == item.needs_search,
                "positive_score": round(pos_score, 4),
                "negative_score": round(neg_score, 4),
                "latency_ms": elapsed_ms,
            }
        )

    return summarize(model_name, "embedding_similarity", load_ms, rows, latencies, cache_dir)


def eval_trained_embeddings(model_name: str, cache_dir: Path) -> Dict[str, Any]:
    from sentence_transformers import SentenceTransformer
    from sklearn.linear_model import LogisticRegression

    started = time.perf_counter()
    model = SentenceTransformer(model_name, cache_folder=str(cache_dir))
    train_texts = TRAIN_POSITIVE + TRAIN_NEGATIVE
    train_labels = [1] * len(TRAIN_POSITIVE) + [0] * len(TRAIN_NEGATIVE)
    train_embeddings = model.encode(train_texts, normalize_embeddings=True)
    classifier = LogisticRegression(
        C=1.0,
        class_weight="balanced",
        solver="liblinear",
        random_state=7,
    ).fit(train_embeddings, train_labels)
    load_ms = int((time.perf_counter() - started) * 1000)

    rows = []
    latencies = []
    for item in EXAMPLES:
        t0 = time.perf_counter()
        emb = model.encode([item.text], normalize_embeddings=True)
        positive_score = float(classifier.predict_proba(emb)[0][1])
        negative_score = 1.0 - positive_score
        elapsed_ms = int((time.perf_counter() - t0) * 1000)
        latencies.append(elapsed_ms)

        predicted = positive_score >= 0.5
        rows.append(
            {
                "text": item.text,
                "category": item.category,
                "expected_needs_search": item.needs_search,
                "predicted_needs_search": predicted,
                "correct": predicted == item.needs_search,
                "positive_score": round(positive_score, 4),
                "negative_score": round(negative_score, 4),
                "latency_ms": elapsed_ms,
            }
        )

    return summarize(model_name, "embedding_trained_logistic", load_ms, rows, latencies, cache_dir)


def summarize(
    model_name: str,
    method: str,
    load_ms: int,
    rows: List[Dict[str, Any]],
    latencies: List[int],
    cache_dir: Path,
) -> Dict[str, Any]:
    correct = sum(1 for row in rows if row["correct"])
    false_positive = sum(
        1
        for row in rows
        if row["predicted_needs_search"] and not row["expected_needs_search"]
    )
    false_negative = sum(
        1
        for row in rows
        if not row["predicted_needs_search"] and row["expected_needs_search"]
    )
    return {
        "model": model_name,
        "method": method,
        "accuracy": round(correct / len(rows), 4),
        "correct": correct,
        "total": len(rows),
        "false_positive": false_positive,
        "false_negative": false_negative,
        "load_ms": load_ms,
        "mean_latency_ms": int(statistics.mean(latencies)),
        "median_latency_ms": int(statistics.median(latencies)),
        "p95_latency_ms": int(sorted(latencies)[int(len(latencies) * 0.95) - 1]),
        "cache_size_mb": model_dir_size_mb(cache_dir, model_name),
        "rows": rows,
    }


def write_markdown(results: List[Dict[str, Any]], out_path: Path) -> None:
    lines = [
        "# ToyTalk Search Router Bake-off",
        "",
        "Goal: choose a tiny local model that decides whether a child question needs current/live web information.",
        "",
        "## Summary",
        "",
        "| Model | Method | Accuracy | False + | False - | Median ms | Cache MB |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for result in sorted(results, key=lambda r: (-r["accuracy"], r["median_latency_ms"], r["cache_size_mb"])):
        lines.append(
            f"| `{result['model']}` | {result['method']} | "
            f"{result['correct']}/{result['total']} | {result['false_positive']} | "
            f"{result['false_negative']} | {result['median_latency_ms']} | {result['cache_size_mb']} |"
        )

    lines.extend(["", "## Per-question results", ""])
    for result in results:
        lines.extend(
            [
                f"### `{result['model']}`",
                "",
                "| Expected | Predicted | OK | Pos score | Neg score | ms | Question |",
                "|---:|---:|---:|---:|---:|---:|---|",
            ]
        )
        for row in result["rows"]:
            ok = "yes" if row["correct"] else "NO"
            lines.append(
                f"| {row['expected_needs_search']} | {row['predicted_needs_search']} | {ok} | "
                f"{row['positive_score']} | {row['negative_score']} | {row['latency_ms']} | "
                f"{row['text']} |"
            )
        lines.append("")

    out_path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        default=str(Path.home() / "Downloads" / "ToyTalk" / "bakeoff" / "search-router"),
    )
    parser.add_argument(
        "--models",
        nargs="*",
        default=[
            "MoritzLaurer/xtremedistil-l6-h256-zeroshot-v1.1-all-33",
            "typeform/mobilebert-uncased-mnli",
            "MoritzLaurer/DeBERTa-v3-xsmall-mnli-fever-anli-ling-binary",
            "sentence-transformers/all-MiniLM-L6-v2",
            "trained:sentence-transformers/paraphrase-MiniLM-L3-v2",
            "trained:sentence-transformers/all-MiniLM-L6-v2",
        ],
    )
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    cache_dir = output_dir / "hf-cache"
    cache_dir.mkdir(parents=True, exist_ok=True)

    results = []
    failures = []
    for model_name in args.models:
        print(f"==> Evaluating {model_name}", flush=True)
        try:
            if model_name.startswith("trained:"):
                result = eval_trained_embeddings(model_name.removeprefix("trained:"), cache_dir)
                result["model"] = model_name
            elif model_name.startswith("sentence-transformers/"):
                result = eval_embeddings(model_name, cache_dir)
            else:
                result = eval_zero_shot(model_name, cache_dir)
            results.append(result)
            print(
                f"    accuracy={result['correct']}/{result['total']} "
                f"median={result['median_latency_ms']}ms size={result['cache_size_mb']}MB",
                flush=True,
            )
        except Exception as exc:  # noqa: BLE001 - this is an experiment harness.
            failures.append({"model": model_name, "error": repr(exc)})
            print(f"    FAILED: {exc!r}", flush=True)

    payload = {
        "examples": [item.__dict__ for item in EXAMPLES],
        "results": results,
        "failures": failures,
    }
    json_path = output_dir / "search_router_bakeoff_results.json"
    md_path = output_dir / "search_router_bakeoff_results.md"
    json_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    write_markdown(results, md_path)
    print(f"Wrote {json_path}")
    print(f"Wrote {md_path}")
    if failures:
        print("Failures:")
        print(json.dumps(failures, indent=2))
    return 0 if results else 1


if __name__ == "__main__":
    raise SystemExit(main())
