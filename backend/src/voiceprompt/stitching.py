import re

_TOKEN = re.compile(r"\S+")


def stitch_segments(segments: list[str], max_overlap_words: int = 24) -> str:
    """Join ordered transcripts while deterministically removing boundary overlap."""
    result: list[str] = []
    for segment in segments:
        current = _TOKEN.findall(segment.strip())
        if not current:
            continue
        overlap = 0
        limit = min(max_overlap_words, len(result), len(current))
        normalized_result = [word.casefold().strip(".,:;!?") for word in result]
        normalized_current = [word.casefold().strip(".,:;!?") for word in current]
        for size in range(limit, 1, -1):
            if normalized_result[-size:] == normalized_current[:size]:
                overlap = size
                break
        result.extend(current[overlap:])
    return " ".join(result)
