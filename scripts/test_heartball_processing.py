#!/usr/bin/env python3
"""Evidence/recovery regression tests. Synthetic text is never an ASR quality score."""
import datetime as dt
import json
from pathlib import Path
import tempfile
import threading
import unittest
import uuid

from heartball_store import Store, Conflict
from heartball_processing import Processor, remove_invented_recording_preface
from heartball_agent_store import AgentStore, stable


class FakeModel:
    def __init__(self): self.calls = 0
    def extract(self, doc, memory):
        self.calls += 1
        kind = "dependency" if "接口" in doc["text"] else "commitment"
        return {"title": "模拟整理", "summary": doc["text"], "claims": [{"project": "云杉", "kind": kind,
            "statement": doc["text"], "owner": "小林", "due_at": "2026-10-24T12:00:00+08:00" if kind == "dependency" else "2026-10-23T12:00:00+08:00",
            "quote": doc["text"], "replaces_id": None}]}
    def answer(self, question, memory):
        return {"answer": ";".join(x["owner"]+":"+x["statement"] for x in memory), "refs": [{"id": x["id"], "version": x["version"]} for x in memory]}


class FakeASR:
    def __init__(self): self.calls = 0
    def transcribe(self, raw, destination):
        self.calls += 1
        return {"text": "云杉接口预计完成", "segments": [], "provider": "synthetic"}


class ProcessingTests(unittest.TestCase):
    def test_model_indices_resolve_only_from_immutable_source_context(self):
        from heartball_processing import expand_merge_indices,expand_activity_ranges,merge_source_anchor
        events=[{'id':str(uuid.uuid4()),'version':i+1,'title':'事项'+str(i),'sources':[{'quote':'可定位的原文证据'+str(i)}]} for i in range(4)]
        merged=expand_merge_indices({'merges':[{'title':'事项','summary':'实际进展','event_indices':[0,2],'evidence':[{'index':i,'source_title':events[i]['title'],'anchor':merge_source_anchor(events[i],events[i]['sources'][0])} for i in [0,2]]}]},events)
        self.assertEqual(merged['merges'][0]['events'],[{k:events[i][k] for k in ['id','version']} for i in [0,2]])
        for indices in ([0,0],[-1,1],[0,8]):
            with self.assertRaises(ValueError):expand_merge_indices({'merges':[{'title':'事项','summary':'进展','event_indices':indices}]},events)
        with self.assertRaises(ValueError):
            expand_merge_indices({'merges':[{'title':'虚假关联','summary':'不应入库','event_indices':[0,2],'evidence':[{'index':0,'source_title':'错误旧标题','anchor':'q_invalid'},{'index':2,'source_title':'不属于当前来源','anchor':'q_invalid'}]}]},events)
        def activity(start,end):return dict(title='讨论',summary='上下文',kind='conversation',start_index=start,end_index=end,boundary_reason='有来源的讨论')
        good=expand_activity_ranges({'activities':[activity(0,1),activity(2,3)]},events)
        self.assertEqual([r for a in good['activities'] for r in a['events']],[{k:e[k] for k in ['id','version']} for e in events])
        for groups in ([activity(0,1),activity(1,3)],[activity(1,3)],[activity(0,2)]):
            with self.assertRaises(ValueError):expand_activity_ranges({'activities':groups},events)

    def test_independent_review_rejects_groups_without_rewriting_sources(self):
        from heartball_processing import reviewed_merges
        value={'merges':[{'title':'同一具体事项','events':[{'id':'a'},{'id':'b'}]},{'title':'只是同一大类','events':[{'id':'c'},{'id':'d'}]}]}
        decisions={'decisions':[{'group_index':0,'same_matter':True,'reason':'同一对象和问题的延续'},{'group_index':1,'same_matter':False,'reason':'不同具体事项'}]}
        self.assertEqual(reviewed_merges(value,decisions),{'merges':[value['merges'][0]]})
        with self.assertRaises(ValueError):reviewed_merges(value,{'decisions':[decisions['decisions'][0]]})

    def test_batch_size_does_not_become_a_recording_duration(self):
        self.assertEqual(remove_invented_recording_preface('一段约60分钟的语音转写，内容涉及赛事预测。','聊聊今天赛事的预测。'),'内容涉及赛事预测。')
        for text in ('午饭聊了30分钟，之后继续项目讨论。','周会持续两个半小时。','一段60分钟的录音需要处理。'):
            self.assertEqual(remove_invented_recording_preface(text,text),text)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name))
        self.model, self.asr = FakeModel(), FakeASR()
        self.processor = Processor(self.store, self.model, self.asr)
        self.agent = self.processor.agent

    def tearDown(self):
        self.processor.close(); self.store.db.close(); self.temp.cleanup()

    def session(self, source="live_conversation", asr=True, agent=True):
        sid = str(uuid.uuid4())
        self.store.create_session(sid); self.store.update_session(sid, status="recording")
        self.agent.policy(sid, asr=asr, agent=agent, source_kind=source, occurred_at="2026-10-21T12:00:00+08:00")
        return sid

    def audio(self, sid, data, offset=0):
        folder = Path(self.store.session(sid)["directory"]) / "probe"; folder.mkdir(exist_ok=True)
        p = folder / "audio-synthetic-AE22.bin"
        with p.open("ab") as f:f.write(data)
        self.store.ingest(sid, {"audioFile": p.name, "audioOffset": offset, "audioBytes": len(data), "time": "synthetic"})

    def run_jobs(self):
        for _ in range(30):
            if not self.processor.tick():break

    def doc(self, text, kind="ambient", source="verified_text", occurred=True):
        sid = self.session(source)
        doc = {"id": str(uuid.uuid4()), "input_key": str(uuid.uuid4()), "session_id": sid, "kind": kind,
            "text": text, "evidence": [], "source_kind": source, "occurred_at": "2026-10-21T12:00:00+08:00" if occurred else None,
            "boundary_quality": "user_text"}
        self.processor.run_document(doc, str(uuid.uuid4()))
        self.store.update_session(sid, status="completed")
        return doc

    def feedback(self, claim, action, values=None, rid=None):
        body = {"id": rid or str(uuid.uuid4()), "target_id": claim["id"], "expected_version": claim["version"], "action": action}
        if values is not None:body["values"] = values
        self.agent.feedback(body)
        return body

    def test_live_batches_and_focus_share_transcripts_no_duplicate_memories(self):
        sid = self.session(); self.audio(sid, b"a" * 40000)
        fid = str(uuid.uuid4()); self.store.focus_start(fid,sid)
        self.audio(sid,b"b" * 120000,40000)
        self.audio(sid,b"c" * 20000,160000)
        self.store.focus_end(fid)
        self.run_jobs()
        state = self.agent.state()
        self.assertEqual(self.asr.calls,3)
        self.assertEqual(len(state["documents"]),4) # three ambient + independent focus
        focus = next(d for d in state["documents"] if d["kind"] == "focus")
        self.assertEqual(focus["boundary_quality"],"batch_exact")
        self.assertEqual(len(focus["evidence"]),2)
        self.assertEqual(len(state["claims"]),3) # focus never duplicates canonical claims
        self.assertEqual(self.store.session(sid)["status"],"recording")
        self.run_jobs(); self.assertEqual(self.asr.calls,3)

    def test_no_permission_never_calls_provider(self):
        sid=self.session(asr=False,agent=False);self.audio(sid,b"a"*120000)
        self.run_jobs(); self.assertEqual(self.asr.calls,0);self.assertEqual(self.model.calls,0)

    def test_source_filter_and_unknown_dates(self):
        self.doc("画面中演员说我答应交付",source="background_playback")
        self.assertEqual(len(self.agent.state()["claims"]),0)
        self.doc("云杉项目下周交付",occurred=False)
        self.assertIsNone(self.agent.state()["claims"][0]["due_at"])
        self.assertEqual(self.agent.context(),[]) # proposals never become confirmed memory

    def test_cross_dialogue_feedback_invalidates_and_timer_rechecks(self):
        self.doc("云杉接口十月二十四日完成")
        self.doc("云杉项目十月二十三日交付")
        for c in self.agent.state()["claims"]:self.feedback(c,"confirm")
        state=self.agent.state();conflict=next(a for a in state["advice"] if a["kind"]=="dependency_conflict")
        self.assertEqual(conflict["status"],"active");self.assertEqual(len(conflict["evidence"]),2)
        c=next(c for c in state["claims"] if c["kind"]=="commitment")
        body=self.feedback(c,"correct",{"due_at":"2026-10-25T12:00:00+08:00","owner":"客户"})
        self.agent.feedback(body) # same receipt no second version
        state=self.agent.state();new=next(x for x in state["claims"] if x["id"]==c["id"])
        self.assertEqual(new["version"],c["version"]+1)
        self.assertEqual(new["owner"],"客户")
        self.assertEqual(next(a for a in state["advice"] if a["id"]==conflict["id"])["status"],"invalidated")
        self.agent.evaluate(dt.datetime(2026,10,26,tzinfo=dt.timezone.utc))
        self.assertTrue(any(a["kind"]=="due" and a["status"]=="active" for a in self.agent.state()["advice"]))
        self.feedback(new,"complete")
        self.agent.evaluate(dt.datetime(2026,10,26,tzinfo=dt.timezone.utc))
        self.assertFalse(any(a["kind"]=="due" and a["status"]=="active" for a in self.agent.state()["advice"]))
        with self.assertRaises(Conflict):self.feedback(c,"reject") # optimistic version conflict

    def test_hallucinated_quote_rolls_back(self):
        sid=self.session()
        doc={"id":str(uuid.uuid4()),"input_key":"test","session_id":sid,"kind":"ambient","text":"真实原句", "evidence":[],"source_kind":"live_conversation","boundary_quality":"batch_exact"}
        result={"title":"标题","summary":"摘要","claims":[{"project":"云杉","kind":"fact","statement":"虚构","owner":"unknown","quote":"不存在的句子"}]}
        with self.assertRaises(ValueError):self.agent.commit_document(doc,result)
        self.assertEqual(self.agent.state()["documents"],[])

    def test_checkpoint_resumes_after_persist_failure_without_second_model_call(self):
        sid=self.session();doc={"id":str(uuid.uuid4()),"input_key":"resume","session_id":sid,"kind":"ambient","text":"云杉接口完成", "evidence":[],"source_kind":"live_conversation","boundary_quality":"batch_exact"}
        original=self.agent.commit_document
        def fail(*args):raise RuntimeError("synthetic disk error")
        self.agent.commit_document=fail
        task=str(uuid.uuid4())
        with self.assertRaises(RuntimeError):self.processor.run_document(doc,task)
        self.agent.commit_document=original
        self.processor.run_document(doc,task)
        self.assertEqual(self.model.calls,1);self.assertEqual(len(self.agent.state()["documents"]),1)
        self.processor.run_document(doc,task);self.assertEqual(self.model.calls,1)

    def test_expired_lease_and_completed_audio_are_reused(self):
        sid=self.session();self.audio(sid,b"a"*120000);self.agent.schedule()
        old=self.agent.claim_job("old",clock=1)
        self.assertIsNotNone(old)
        new=self.agent.claim_job("new",clock=602)
        self.assertEqual(new["id"],old["id"])
        self.agent.job_done(new)
        self.assertIsNone(self.agent.claim_job("third",clock=603))

    def test_mute_and_feedback_receipt_conflict(self):
        self.doc("云杉项目交付")
        self.agent.evaluate(dt.datetime(2026,10,26,tzinfo=dt.timezone.utc))
        advice=self.agent.state()["advice"][0]
        r={"id":str(uuid.uuid4()),"target_id":advice["id"],"action":"mute_kind"}
        self.agent.feedback(r);self.agent.evaluate()
        self.assertFalse(any(x["status"]=="active" for x in self.agent.state()["advice"]))
        with self.assertRaises(Conflict):self.agent.feedback({**r,"action":"dismiss"})

    def test_query_uses_corrected_memory_and_becomes_stale_after_edit(self):
        self.doc("云杉项目交付")
        c=self.agent.state()["claims"][0];self.feedback(c,"correct",{"owner":"客户"})
        qid=str(uuid.uuid4());self.agent.ask(qid,"谁交付？");self.run_jobs()
        answer=self.agent.state()["answers"][0]
        self.assertEqual(answer["status"],"ready");self.assertIn("客户",answer["answer"])
        c=self.agent.context()[0];self.feedback(c,"correct",{"owner":"小王"})
        self.assertEqual(self.agent.state()["answers"][0]["status"],"outdated")

    def test_transcript_correction_preserves_source_and_never_retranscribes(self):
        doc=self.doc("云杉接口完成")
        c=self.agent.state()["claims"][0];self.feedback(c,"confirm")
        calls=self.asr.calls
        self.agent.feedback({"id":str(uuid.uuid4()),"target_id":doc["id"],"action":"correct_document","expected_version":1,"values":{"text":"云杉项目延期交付"}})
        self.run_jobs()
        state=self.agent.state()
        self.assertEqual(self.asr.calls,calls)
        self.assertEqual(next(d for d in state["documents"] if d["id"]==doc["id"])["status"],"superseded")
        self.assertEqual(next(x for x in state["claims"] if x["id"]==c["id"])["status"],"superseded")
        self.assertTrue(any(d["text"]=="云杉项目延期交付" for d in state["documents"]))

    def test_unverifiable_candidate_is_excluded_with_visible_warning(self):
        class BadQuote(FakeModel):
            def extract(self,doc,memory):
                result=super().extract(doc,memory);result["claims"][0]["quote"]="不存在的原句";return result
        self.processor.model=BadQuote()
        self.doc("云杉项目交付")
        state=self.agent.state()
        self.assertEqual(state["claims"],[])
        self.assertTrue(state["documents"][0]["validation_notes"])

    def test_passive_facts_stay_quiet_and_source_reclassification_removes_claims(self):
        class Facts(FakeModel):
            def extract(self,doc,memory):
                result=super().extract(doc,memory);result["claims"][0]["kind"]="fact";return result
        self.processor.model=Facts();doc=self.doc("对话中的一般事实")
        self.assertEqual(self.agent.state()["advice"],[])
        c=self.agent.state()["claims"][0];self.feedback(c,"confirm")
        self.agent.feedback({"id":str(uuid.uuid4()),"target_id":doc["id"],"expected_version":1,
            "action":"reclassify_document","values":{"source_kind":"background_playback"}})
        self.run_jobs()
        self.assertEqual(self.agent.context(),[])
        self.assertEqual(sum(c["status"]=="proposed" for c in self.agent.state()["claims"]),0)

    def test_capture_ingest_policy_and_ui_reads_can_run_concurrently(self):
        sid=self.session();folder=Path(self.store.session(sid)["directory"])/"probe";folder.mkdir()
        name="audio-concurrent-AE22.bin";(folder/name).write_bytes(b"a"*160*500)
        errors=[]
        def read():
            try:
                for _ in range(500):
                    self.store.session(sid);self.store.state();self.agent.allowed(sid,"asr");self.agent.state()
            except BaseException as e:errors.append(e)
        def write():
            try:
                for i in range(500):self.store.ingest(sid,{"audioFile":name,"audioOffset":i*160,"audioBytes":160,"time":"synthetic"})
            except BaseException as e:errors.append(e)
        threads=[threading.Thread(target=read) for _ in range(3)]+[threading.Thread(target=write)]
        for t in threads:t.start()
        for t in threads:t.join(8)
        self.assertFalse(any(t.is_alive() for t in threads));self.assertEqual(errors,[])
        self.assertEqual(self.store.state()["session"]["audioSeconds"],40)

    def test_unconfirmed_dialogue_is_retrievable_without_personal_attribution(self):
        self.doc("我计划下周交付")
        claim=self.agent.state()["claims"][0]
        self.assertEqual(self.agent.context(), [])
        context=self.agent.query_context()
        self.assertEqual(context[0]["record_type"], "mention")
        qid=str(uuid.uuid4());self.agent.ask(qid,"刚才提了什么？")
        self.agent.answer(qid,{"answer":"刚才提到我计划下周交付。", "refs":[{"id":claim["id"],"version":claim["version"]}]})
        answer=self.agent.state()["answers"][0]
        self.assertIn("我计划下周交付", answer["answer"])
        self.assertEqual("刚才提到我计划下周交付。", answer["answer"])
        self.assertEqual(self.agent.state()["confirmedMemoryCount"],0)
        self.feedback(claim,"reject")
        self.assertEqual(self.agent.state()["answers"][0]["status"],"outdated")

    def test_background_record_recall_needs_exact_quote_and_revision(self):
        doc=self.doc("视频里说我准备下周发货",source="background_playback")
        self.assertEqual(self.agent.state()["claims"],[])
        record=self.agent.query_context()[0]
        self.assertEqual(record["record_type"],"record")
        qid=str(uuid.uuid4());self.agent.ask(qid,"视频说什么？")
        with self.assertRaises(Conflict):
            self.agent.answer(qid,{"answer":"虚构", "refs":[{"id":doc["id"],"version":1,"quote":"不存在的原话"}]})
        self.agent.answer(qid,{"answer":"你要发货", "refs":[{"id":doc["id"],"version":1,"quote":"我准备下周发货"}]})
        self.assertIn("背景播放",self.agent.state()["answers"][0]["answer"])
        self.assertNotIn("你要发货",self.agent.state()["answers"][0]["answer"])
        self.agent.feedback({"id":str(uuid.uuid4()),"target_id":doc["id"],"expected_version":1,"action":"correct_document","values":{"text":"视频里说另一个日期"}})
        self.assertEqual(self.agent.state()["answers"][0]["status"],"outdated")
        with self.assertRaises(Conflict):
            self.agent.answer(qid,{"answer":"旧", "refs":[{"id":doc["id"],"version":1,"quote":"我准备下周发货"}]})

    def test_ordinary_mentions_do_not_require_review_advice(self):
        self.doc("云杉项目十月二十三日交付")
        self.assertFalse(any(a["kind"]=="review_intent" and a["status"]=="active" for a in self.agent.state()["advice"]))
        self.agent.evaluate(dt.datetime(2026,10,26,tzinfo=dt.timezone.utc))
        self.assertTrue(any(a["kind"]=="due_observed" and a["status"]=="active" for a in self.agent.state()["advice"]))
        self.assertEqual(self.agent.state()["confirmedMemoryCount"],0)

    def test_slow_document_model_does_not_block_next_audio_transcription(self):
        entered=threading.Event();release=threading.Event();original=self.model.extract
        def slow(doc,memory):
            entered.set();release.wait(5);return original(doc,memory)
        self.model.extract=slow
        sid=self.session();self.audio(sid,b'a'*120000)
        self.processor.start()
        self.assertTrue(entered.wait(3))
        self.audio(sid,b'b'*120000,120000)
        import time
        deadline=time.monotonic()+3
        while self.asr.calls<2 and time.monotonic()<deadline:time.sleep(.02)
        try:self.assertEqual(self.asr.calls,2)
        finally:release.set()

    def test_filler_is_retained_without_creating_semantic_or_personal_fact(self):
        doc=self.doc('哎呀')
        state=self.agent.state()
        self.assertEqual(self.model.calls,0)
        self.assertEqual(state['documents'][0]['text'],'哎呀')
        self.assertEqual(state['documents'][0]['status'],'transcript_only')
        self.assertEqual(state['events'],[])
        from heartball_content import has_semantic_content
        for text in ('吃药','喝水','着火','到了','明天交付'):self.assertTrue(has_semantic_content(text))

    def test_empty_asr_text_is_not_a_model_summary_or_a_personal_fact(self):
        self.doc("")
        state=self.agent.state()
        self.assertEqual(self.model.calls,0)
        self.assertEqual(state["documents"][0]["status"],"no_text")
        self.assertEqual(state["claims"],[])
        self.assertEqual(state["advice"],[])


if __name__ == "__main__":unittest.main()
