#!/usr/bin/env python3
"""Isolated synthetic-dialogue integration check using a real configured model.

Never mixes fictional claims into the user's live store. This is not an ASR
accuracy test; it checks actual model extraction + revisions + proactive rules.
"""
import argparse
import datetime as dt
import json
from pathlib import Path
import uuid

from heartball_store import Store
from heartball_processing import Processor, ModelAdapter


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True)
    args=parser.parse_args()
    if args.output.exists():parser.error("Choose a fresh private output directory")
    args.output.mkdir(parents=True,mode=0o700)
    cfg=json.loads(args.config.read_text())
    store=Store(args.output)
    processor=Processor(store,ModelAdapter(cfg["model"]))
    agent=processor.agent
    results={"fixture":"synthetic_dialogues_not_user_memory", "real_model":cfg["model"]["model"],"checks":{}}
    samples=[
        "以下为虚构验收对话，不是真实用户经历。项目名称：云杉。已确认的依赖：小林说，云杉的接口将在2026年10月24日12:00（北京时间）准备好。",
        "以下为虚构验收对话，不是真实用户经历。项目名称：云杉。已确认的交付承诺：小王说，我将在2026年10月23日12:00（北京时间）交付云杉完整版本，交付依赖小林的接口。"]
    for i,text in enumerate(samples):
        sid=str(uuid.uuid4());session=store.create_session(sid);store.update_session(sid,status="completed")
        agent.policy(sid,asr=False,agent=True,source_kind="verified_text",occurred_at="2026-10-21T12:00:00+08:00")
        did=str(uuid.uuid4())
        doc={"id":did,"input_key":"fixture:"+did,"session_id":sid,"kind":"text","text":text,"evidence":[{"kind":"synthetic_fixture"}],
            "source_kind":"verified_text","occurred_at":"2026-10-21T12:00:00+08:00","boundary_quality":"user_text"}
        processor.run_document(doc,str(uuid.uuid4()))
        proposals=[c for c in agent.state()["claims"] if c["document_id"]==did]
        assert proposals,"Real model returned no claims"
        for c in proposals:
            # Explicit synthetic-test operator confirmation, never silent approval
            # of real audio or private user statements.
            agent.feedback({"id":str(uuid.uuid4()),"target_id":c["id"],"action":"confirm","expected_version":c["version"]})
        results["checks"][f"dialogue_{i+1}_extracted_confirmed"]=True
        print('real model dialogue',i+1,'committed',len(proposals),'claims',flush=True)
    state=agent.state()
    conflicts=[a for a in state["advice"] if a["kind"]=="dependency_conflict" and a["status"]=="active"]
    assert conflicts,"No evidence-backed cross-dialogue conflict detected"
    results["checks"]["proactive_cross_dialogue_conflict_without_chat_query"]=True
    c=next(c for c in state["claims"] if c["kind"]=="commitment" and c["status"]=="confirmed")
    request={"id":str(uuid.uuid4()),"target_id":c["id"],"action":"correct","expected_version":c["version"],
             "values":{"owner":"客户小王","due_at":"2026-10-25T12:00:00+08:00"}}
    agent.feedback(request);agent.feedback(request)
    state=agent.state()
    assert all(next(a for a in state["advice"] if a["id"]==x["id"])["status"]=="invalidated" for x in conflicts)
    results["checks"]["correction_invalidates_old_advice"]=True
    corrected=next(x for x in agent.context() if x["id"]==c["id"])
    assert corrected["owner"]=="客户小王" and corrected["version"]==c["version"]+1
    results["checks"]["correction_visible_to_next_model_context"]=True
    results["checks"]["feedback_retry_idempotent"]=True
    qid=str(uuid.uuid4());agent.ask(qid,"云杉项目当前由谁交付，什么时候交付？")
    processor.run_query({"question_id":qid,"question":"云杉项目当前由谁交付，什么时候交付？"},str(uuid.uuid4()))
    answer=agent.state()["answers"][0]
    assert answer["status"]=="ready" and any(r["id"]==c["id"] and r["version"]==corrected["version"] for r in answer["refs"])
    assert "客户小王" in answer["answer"] and "2026-10-25" in answer["answer"], "Query prose ignored corrected fields"
    results["checks"]["real_model_query_cites_corrected_version"]=True
    results["checks"]["real_model_query_uses_corrected_owner_and_date"]=True
    agent.evaluate(dt.datetime(2026,10,26,tzinfo=dt.timezone.utc))
    assert any(a["kind"]=="due" and a["status"]=="active" for a in agent.state()["advice"])
    results["checks"]["timer_wakes_due_followup"]=True
    agent.feedback({"id":str(uuid.uuid4()),"target_id":corrected["id"],"action":"complete","expected_version":corrected["version"]})
    agent.evaluate(dt.datetime(2026,10,26,tzinfo=dt.timezone.utc))
    assert not any(a["kind"]=="due" and a["status"]=="active" for a in agent.state()["advice"])
    results["checks"]["completion_cancels_stale_due_advice"]=True
    before=agent.state();processor.close();store.db.close()
    store=Store(args.output);processor=Processor(store,ModelAdapter(cfg["model"]))
    after=processor.agent.state()
    assert before==after
    results["checks"]["restart_preserves_memory_feedback_and_advice"]=True
    results["all_passed"]=True
    results["not_validated"]=["real ASR accuracy", "general autonomous planning", "push delivery outside the App"]
    (args.output/'result.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
    processor.close();store.db.close()
    print(json.dumps(results,ensure_ascii=False),flush=True)


if __name__=="__main__":main()
