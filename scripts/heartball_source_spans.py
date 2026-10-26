"""Shared exact-source anchors. IDs select text; a model never retypes evidence."""
import re

def source_spans(text):
    # Reuse the existing lossless refinement splitter. Short clauses retain
    # referents; long ASR sentences no longer force unrelated matters together.
    from heartball_event_refinement import source_atoms
    return source_atoms(text)
