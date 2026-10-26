"""Whole-ledger lexical recall on SQLite FTS5, independent of UI preview limits.

Trigram LIKE supports CJK substrings. Two-character names correctly fall back to
SQLite's scan instead of silently disappearing. This is not vector/semantic search.
"""
import re

STOP = {'什么','怎么','现在','今天','最近','记录','一下','我们','哪些','情况','是否','还有'}

def terms(text):
    found = re.findall(r'[a-z0-9_]{2,}', text.lower())
    for span in re.findall(r'[\u4e00-\u9fff]+', text):
        if len(span) <= 10: found.append(span)
        for n in (3, 2):
            found.extend(span[i:i+n] for i in range(len(span)-n+1))
    return list(dict.fromkeys(t for t in found if t not in STOP))[:32]


class RecallIndex:
    def __init__(self, db):
        self.db = db
        # Native SQL triggers keep the ledger and derived index in one transaction.
        # No Python UDF is needed by migrations, corrections or maintenance clients.
        db.execute("CREATE VIRTUAL TABLE IF NOT EXISTS memory_search USING fts5(kind UNINDEXED,record_id UNINDEXED,body,tokenize='trigram')")
        tables = {
            'claims': ('claim', ['project','statement','owner'], "status IN ('proposed','confirmed','completed')"),
            'documents': ('record', ['title','summary','text'], "status NOT IN ('superseded','no_text')"),
            'workspace_events': ('event', ['title','summary'], "status='active'"),
            'workspace_topics': ('topic', ['title','summary'], "status='active'")}
        for table,(kind,fields,active) in tables.items():
            def body(prefix): return " || ' ' || ".join(f"coalesce({prefix}{f},'')" for f in fields)
            for suffix,operation in [('insert','INSERT'),('update','UPDATE'),('delete','DELETE')]:
                sql = f"DELETE FROM memory_search WHERE kind='{kind}' AND record_id=old.id;" if suffix!='insert' else ''
                if suffix!='delete':
                    where = re.sub(r'\bstatus\b','new.status',active)
                    sql += f"INSERT INTO memory_search(kind,record_id,body) SELECT '{kind}',new.id,{body('new.')} WHERE {where};"
                db.execute(f"CREATE TRIGGER IF NOT EXISTS recall_{table}_{suffix} AFTER {operation} ON {table} BEGIN {sql} END")
            # An empty per-type index is a valid existing ledger migration. Once
            # initialized, triggers alone maintain it, including source retractions.
            if not db.execute("SELECT 1 FROM memory_search WHERE kind=? LIMIT 1",(kind,)).fetchone():
                db.execute(f"INSERT INTO memory_search(kind,record_id,body) SELECT ?,id,{body('')} FROM {table} WHERE {active}",(kind,))
        db.commit()

    def search(self, question, limit=160):
        words=terms(question)
        if not words:return []
        patterns=['%'+w.replace('\\','\\\\').replace('%','\\%').replace('_','\\_')+'%' for w in words]
        predicate="body LIKE ? ESCAPE '\\'"
        score=' + '.join(f"CASE WHEN {predicate} THEN {min(len(w),12)} ELSE 0 END" for w in words)
        where=' OR '.join([predicate]*len(words))
        return [dict(r) for r in self.db.execute(f"SELECT kind,record_id,({score}) AS score FROM memory_search WHERE {where} ORDER BY score DESC,rowid DESC LIMIT ?",patterns+patterns+[max(1,min(300,limit))])]
