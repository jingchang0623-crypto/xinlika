"""Recording-day completeness, meeting containers and midnight regressions; no model calls."""
import json
from pathlib import Path
import tempfile
import unittest
import uuid
from heartball_store import Store, now
from heartball_agent_store import AgentStore
from heartball_day import daily_workspace


class DayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name)); self.agent = AgentStore(self.store)
        self.db = self.store.db

    def tearDown(self):
        self.db.close(); self.temp.cleanup()

    def event(self, stamp, session=None, kind='ambient', duration=0, source='live_conversation'):
        sid = session or str(uuid.uuid4())
        if not self.db.execute('SELECT 1 FROM sessions WHERE id=?', (sid,)).fetchone():
            self.store.create_session(sid)
            self.store.update_session(sid,status='completed')
        eid, did = str(uuid.uuid4()), str(uuid.uuid4())
        evidence = [{'start_byte': 0, 'end_byte': duration * 2000}]
        self.db.execute("INSERT INTO documents(id,kind,session_id,input_key,text,evidence,title,summary,source_kind,status,created_at,occurred_at,boundary_quality) VALUES(?,?,?,?,?,?,?,?,?,'active',?,?,?)", (did,kind,sid,did,'原句',json.dumps(evidence),'事项','摘要',source,now(),stamp,'batch_exact'))
        self.db.execute("INSERT INTO workspace_events VALUES(?,?,?,?,?,?,?,'active',1,?,?)", (eid,sid,kind,'事项','摘要',source,stamp,now(),now()))
        self.db.execute("INSERT INTO workspace_event_sources VALUES(?,?,1,'原句','literal_anchor')", (eid,did))
        return eid, did, sid

    def day(self, date='2026-10-21', zone='Asia/Shanghai'):
        return daily_workspace(self.db,date,zone)

    def test_homepage_detail_admission_preserves_original_and_source_change_invalidates_it(self):
        from heartball_timeline import save,signature
        eid,did,sid=self.event('2026-10-21T14:00:00+08:00')
        event=dict(self.db.execute('select * from workspace_events where id=?',(eid,)).fetchone())
        before=self.db.execute('select text from documents where id=?',(did,)).fetchone()[0]
        save(self.db,event,'detail','孤立回应，没有独立事项',signature(self.db,event));self.db.commit()
        self.assertEqual(sum(len(g['events']) for g in self.day()['groups']),0)
        self.assertEqual(self.db.execute('select text from documents where id=?',(did,)).fetchone()[0],before)
        self.assertEqual(self.db.execute('select status from workspace_events where id=?',(eid,)).fetchone()[0],'active')
        self.db.execute("update workspace_events set summary='用户补充了独立事项' where id=?",(eid,))
        self.assertEqual(sum(len(g['events']) for g in self.day()['groups']),1)

    def test_source_bound_homepage_caption_does_not_rewrite_events_or_recording_clock(self):
        from heartball_timeline import save
        eid,_,_=self.event('2026-10-21T14:00:00+08:00')
        e=dict(self.db.execute('select * from workspace_events where id=?',(eid,)).fetchone())
        save(self.db,e,'event','原文重读',headline='具体事项标题',abstract='按原文概括内容');self.db.commit()
        visible=self.day()['groups'][0]['events'][0]
        self.assertEqual(visible['title'],'具体事项标题');self.assertEqual(visible['occurred_at'],e['occurred_at'])
        self.assertEqual(dict(self.db.execute('select * from workspace_events where id=?',(eid,)).fetchone()),e)
        self.db.execute("update workspace_events set summary='已纠正的新内容' where id=?",(eid,))
        self.assertEqual(self.day()['groups'][0]['events'][0]['title'],e['title'])

    def test_user_focus_is_never_hidden_by_homepage_admission(self):
        from heartball_timeline import save
        eid,_,_=self.event('2026-10-21T14:00:00+08:00',kind='focus')
        event=dict(self.db.execute('select * from workspace_events where id=?',(eid,)).fetchone())
        save(self.db,event,'detail','模型误判');self.db.commit()
        self.assertEqual(sum(len(g['events']) for g in self.day()['groups']),1)

    def test_dense_day_is_complete_beyond_recent_caps_and_sources_stay_reachable(self):
        sid = str(uuid.uuid4()); expected = set(); docs = set()
        for minute in range(140):
            eid,did,_ = self.event(f'2026-10-21T{14+minute//60:02}:{minute%60:02}:00+08:00',sid,duration=60)
            expected.add(eid); docs.add(did)
        # Later processing of older recordings must not push today's events out.
        for _ in range(510): self.event('2026-10-20T14:00:00+08:00',sid)
        state = self.agent.state(day='2026-10-21'); day = state['today']
        self.assertEqual(day['event_count'],140); self.assertEqual(len(day['groups']),1)
        self.assertEqual({e['id'] for g in day['groups'] for e in g['events']},expected)
        self.assertTrue(docs.issubset({d['id'] for d in state['documents']}))
        self.assertEqual(len(state['events']),100)  # independent historical preview

    def test_explicit_meeting_scope_groups_samples_without_merging_topics_or_focus(self):
        rows = [self.event('2026-10-21T14:42:00+08:00'),self.event('2026-10-21T14:44:00+08:00')]
        self.event('2026-10-21T14:43:00+08:00',rows[0][2],kind='focus')
        for _,_,sid in rows:
            self.store.event(sid,'recording_context',{'medium':'live_video_meeting','group_id':'meeting-a','reported_start_local':'2026-10-21T14:00:00'})
        unrelated = self.event('2026-10-21T14:45:00+08:00')
        day = self.day(); self.assertEqual(len(day['groups']),2)
        group = next(g for g in day['groups'] if g['kind']=='meeting')
        self.assertEqual((group['session_count'],group['event_count'],group['focus_count']),(2,2,1))
        self.assertTrue(group['start_local'].startswith('2026-10-21T14:42'))
        self.assertTrue(all(e['topic_id'] is None for e in group['events']))
        self.assertNotIn(unrelated[0],{e['id'] for e in group['events']})

    def test_timezone_midnight_overlap_and_unknown_time_never_uses_processing_clock(self):
        previous = self.event('2026-10-20T15:59:00+00:00')[0]
        first = self.event('2026-10-20T16:00:00+00:00')[0]
        crossing = self.event('2026-10-20T15:59:50+00:00',duration=20)[0]
        tomorrow = self.event('2026-10-21T16:00:00+00:00')[0]
        unknown = self.event(None)[0]
        day = self.day(); ids = {e['id'] for g in day['groups'] for e in g['events']}
        self.assertEqual(ids,{first,crossing}); self.assertEqual(day['unknown_time_count'],1)
        self.assertNotIn(previous,ids); self.assertNotIn(tomorrow,ids); self.assertNotIn(unknown,ids)
        next_day = self.day('2026-10-22')
        self.assertEqual({e['id'] for g in next_day['groups'] for e in g['events']},{tomorrow})

    def test_cross_day_event_can_appear_on_both_days_without_duplication(self):
        eid,_,sid = self.event('2026-10-20T23:59:50+08:00',duration=20)
        for day in ('2026-10-20','2026-10-21'):
            result = self.day(day)
            self.assertEqual([e['id'] for g in result['groups'] for e in g['events']],[eid])
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM workspace_events').fetchone()[0],1)

    def test_dst_and_unverified_device_calendar_dates(self):
        inside = self.event('2026-03-09T03:59:00+00:00')[0]
        self.event('2026-03-09T04:00:00+00:00')
        result = self.day('2026-03-08','America/New_York')
        self.assertEqual([e['id'] for g in result['groups'] for e in g['events']],[inside])
        eid,_,sid = self.event(None)
        self.db.execute('INSERT INTO recording_origins VALUES(?,?,?,?,?,?)',(sid,'note20261021-120000.opus','fixture-hash','2026-10-21T12:00:00',0,'{}'))
        event = self.day()['groups'][0]['events'][0]
        self.assertEqual(event['id'],eid); self.assertEqual(event['recording_time_basis'],'device_clock_unverified')
        for day,zone in [('nonsense','Asia/Shanghai'),('2026-10-21','unknown/zone')]:
            with self.assertRaises(ValueError): self.day(day,zone)


if __name__ == '__main__': unittest.main()
