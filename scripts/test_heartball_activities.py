"""Activity projection controls. Durations are synthetic envelopes, not field quality."""
import datetime as dt
import json
from pathlib import Path
import tempfile
import unittest
import uuid
from zoneinfo import ZoneInfo

from heartball_store import Store,now,Conflict
from heartball_agent_store import AgentStore
from heartball_activities import ActivityStore,activity_projection
from heartball_day import daily_workspace


class ActivityTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.store=Store(Path(self.temp.name));self.agent=AgentStore(self.store)
        self.a=ActivityStore(self.agent);self.db=self.store.db
        self.day=dt.datetime.now(ZoneInfo('Asia/Shanghai')).date().isoformat()
        self.sid=str(uuid.uuid4());self.store.create_session(self.sid);self.store.update_session(self.sid,status='completed')
        self.agent.policy(self.sid,asr=False,agent=True,source_kind='live_conversation')
    def tearDown(self):self.db.close();self.temp.cleanup()
    def event(self,hour,minute,duration=60,kind='ambient',sid=None):
        sid=sid or self.sid;eid,did=str(uuid.uuid4()),str(uuid.uuid4());stamp=f'{self.day}T{hour:02}:{minute:02}:00+08:00'
        doc={'id':did,'session_id':sid,'kind':kind,'input_key':did,'text':'项目讨论的实际原句。',
            'evidence':[{'start_byte':0,'end_byte':duration*2000}],'source_kind':'live_conversation',
            'occurred_at':stamp,'boundary_quality':'batch_exact'}
        self.agent.commit_document(doc,{'title':'具体议题','summary':'项目议题','claims':[]})
        with self.store.transaction():
            self.db.execute("INSERT INTO workspace_events VALUES(?,?,?,?,?,?,?,'active',1,?,?)",(eid,sid,kind,'具体议题','项目议题','live_conversation',stamp,now(),now()))
            self.db.execute("INSERT INTO workspace_event_sources VALUES(?,?,1,?,'literal_anchor')",(eid,did,doc['text']))
        return {'id':eid,'version':1}
    def proposal(self,groups):
        return {'activities':[{'title':title,'summary':'综合这次活动的议题与进展。','kind':kind,'boundary_reason':'原文中的交流目的和明确场景变化。','events':refs} for title,kind,refs in groups]}
    def persist(self,groups):
        self.assertTrue(self.a.request(force=True));row=self.db.execute('SELECT * FROM workspace_activity_runs ORDER BY rowid DESC LIMIT 1').fetchone()
        context=json.loads(row['context']);self.a.persist(row['run_key'],self.proposal(groups),context)
        return daily_workspace(self.db,self.day)
    def test_one_recording_contains_30_60_150_minute_activities(self):
        refs=[self.event(12,0,1800),self.event(12,30,3600),self.event(13,30,9000)]
        day=self.persist([('午饭闲聊','meal',[refs[0]]),('项目讨论','project_discussion',[refs[1]]),('周会','meeting',[refs[2]])])
        self.assertEqual({g['title'] for g in day['groups']},{'午饭闲聊','项目讨论','周会'})
        self.assertEqual(sorted(g['observed_audio_seconds'] for g in day['groups']),[1800,3600,9000])
        self.assertEqual(day['event_count'],3)
        self.assertEqual(self.db.execute('SELECT count(*) FROM workspace_event_topics').fetchone()[0],0)
    def test_many_topics_are_one_weekly_meeting_without_claiming_missing_audio(self):
        refs=[self.event(14,0),self.event(15,0),self.event(16,29)]
        day=self.persist([('周会','meeting',refs)]);group=day['groups'][0]
        self.assertEqual(group['event_count'],3);self.assertEqual(group['observed_audio_seconds'],180)
        self.assertTrue(group['start_local'].endswith('14:00:00+08:00'));self.assertTrue(group['end_local'].endswith('16:30:00+08:00'))
        self.assertEqual(group['boundary_precision'],'observed_source_envelope')
    def test_mixed_timezones_sort_by_recording_instant(self):
        first,second=self.event(12,0),self.event(13,0)
        did=self.db.execute('SELECT document_id FROM workspace_event_sources WHERE event_id=?',(second['id'],)).fetchone()[0]
        self.db.execute('UPDATE documents SET occurred_at=? WHERE id=?',(self.day+'T05:00:00+00:00',did));self.db.commit()
        self.assertEqual([e['id'] for e in self.a.context()['events']],[first['id'],second['id']])
    def test_omitted_or_interleaved_issues_are_rejected_atomically(self):
        refs=[self.event(12,0),self.event(12,2),self.event(12,4)];context=self.a.context()
        for groups in [[('遗漏','conversation',refs[:2])],[('交错','conversation',[refs[0],refs[2]]),('中间','conversation',[refs[1]])]]:
            with self.assertRaises(ValueError):self.a.validate(self.proposal(groups),context)
        self.assertEqual(self.db.execute('SELECT count(*) FROM workspace_activities').fetchone()[0],0)
    def test_retry_feedback_identifies_skipped_position_without_weakening_rules(self):
        refs=[self.event(12,0),self.event(12,2),self.event(12,4)]
        wrong=self.proposal([('返回的议题','conversation',[refs[0],refs[2]]),('中间活动','conversation',[refs[1]])])
        correct=self.proposal([('第一次讨论','conversation',[refs[0]]),('中间活动','conversation',[refs[1]]),('再次讨论','conversation',[refs[2]])])
        self.a.request(force=True);run=self.db.execute('SELECT * FROM workspace_activity_runs').fetchone()
        test=self
        class Model:
            calls=0
            def organize_activities(inner,context):
                inner.calls+=1
                if inner.calls==1:return wrong
                test.assertIn('skips 1',context['validation_feedback'])
                test.assertEqual([e['order_index'] for e in context['events']],[0,1,2])
                return correct
        model=Model();self.a.run(run['run_key'],model)
        self.assertEqual(model.calls,2)
        self.assertEqual(self.db.execute("SELECT count(*) FROM workspace_activities WHERE status='active'").fetchone()[0],3)

    def test_overlapping_source_envelopes_are_not_a_proven_interleaving(self):
        refs=[self.event(12,0,duration=120),self.event(12,1,duration=60),self.event(12,1,duration=120)]
        context=self.a.context();ordered=[{'id':e['id'],'version':e['version']} for e in context['events']]
        value=self.a.validate(self.proposal([('交谈','conversation',[ordered[0],ordered[2]]),('同期语音','conversation',[ordered[1]])]),context)
        self.assertEqual(len(value['activities']),2)
    def test_different_explicit_meetings_cannot_be_combined(self):
        first=self.event(12,0);sid=str(uuid.uuid4());self.store.create_session(sid);self.store.update_session(sid,status='completed')
        self.agent.policy(sid,asr=False,agent=True,source_kind='live_conversation');second=self.event(13,0,sid=sid)
        self.store.event(self.sid,'recording_context',{'medium':'live_video_meeting','group_id':'first'})
        self.store.event(sid,'recording_context',{'medium':'live_video_meeting','group_id':'second'})
        with self.assertRaises(ValueError):self.a.validate(self.proposal([('混在一起','meeting',[first,second])]),self.a.context())
    def test_corrected_event_invalidates_projection_and_preserves_all_today_events(self):
        refs=[self.event(12,0),self.event(12,1)];self.persist([('项目讨论','project_discussion',refs)])
        self.db.execute("UPDATE workspace_events SET version=2,status='invalidated' WHERE id=?",(refs[0]['id'],));self.db.commit()
        self.assertEqual(activity_projection(self.db),{})
        self.assertEqual(daily_workspace(self.db,self.day)['event_count'],1)

    def test_continued_same_event_can_extend_while_analysis_is_running(self):
        ref=self.event(12,0);self.a.request(force=True);run=self.db.execute('SELECT * FROM workspace_activity_runs').fetchone();context=json.loads(run['context'])
        self.db.execute('UPDATE workspace_events SET version=2 WHERE id=?',(ref['id'],));self.db.commit()
        self.a.persist(run['run_key'],self.proposal([('项目讨论','project_discussion',[ref])]),context)
        self.db.execute('UPDATE workspace_events SET version=3 WHERE id=?',(ref['id'],));self.db.commit()
        self.assertIn(ref['id'],activity_projection(self.db))
    def test_focus_remains_independent_inside_the_activity(self):
        ref=self.event(12,0,1800);focus=self.event(12,10,60,kind='focus')
        day=self.persist([('午间交流','conversation',[ref])]);self.assertEqual(len(day['groups']),1)
        self.assertEqual((day['event_count'],day['focus_count']),(1,1))
        self.assertEqual({e['id'] for e in day['groups'][0]['events']},{ref['id'],focus['id']})
    def test_revoked_input_never_reaches_model(self):
        self.event(12,0);self.a.request(force=True);key=self.db.execute('SELECT run_key FROM workspace_activity_runs').fetchone()[0]
        self.agent.policy(self.sid,asr=False,agent=False,source_kind='live_conversation')
        class Never:
            def organize_activities(self,context):raise AssertionError('Revoked data sent to model')
        with self.assertRaises(Conflict):self.a.run(key,Never())

    def test_activity_identity_survives_more_issues_and_summary_updates(self):
        first=self.event(12,0);day=self.persist([('项目讨论','project_discussion',[first])]);identity=day['groups'][0]['id']
        # Simulate worker acknowledgement, then add another issue in same activity.
        self.db.execute("UPDATE jobs SET status='completed' WHERE kind='activity_analysis'");self.db.commit()
        second=self.event(12,10);day=self.persist([('项目讨论进展','project_discussion',[first,second])])
        self.assertEqual(identity,day['groups'][0]['id']);self.assertEqual(day['event_count'],2)
    def test_larger_than_validated_context_leaves_full_timeline_available(self):
        for i in range(301):self.event(12+i//60,i%60)
        self.assertFalse(self.a.request(force=True))
        self.assertEqual(self.db.execute('SELECT status FROM workspace_activity_runs').fetchone()[0],'limited')
        self.assertEqual(daily_workspace(self.db,self.day)['event_count'],301)


if __name__=='__main__':unittest.main()
