"""Opt-in strict wire schema. Domain meaning and source validators stay external."""


def object_schema(properties):return dict(type='object',properties=properties,required=list(properties),additionalProperties=False)


def strict_incremental_schema(context):
    text={'type':'string'}
    strings=dict(type='array',items=text)
    state=object_schema(dict(title=text,bullets=strings,people=strings,open_questions=strings))
    recent=[e['id'] for e in context['recent_events']];topics=[t['id'] for t in context['topics']]
    issue=object_schema(dict(key=text,title=text,summary=text,display=dict(type='string',enum=['event','detail']),
        category=dict(type='string',enum=['conversation','work','life','travel','idea','feedback','environment']),
        card_style=dict(type='string',enum=['compact','summary']),admission_reason=text,
        interest_level=dict(type='string',enum=['normal','high','low']),interest_reason=text,interest_example_ids=strings,
        continues_id=dict(type=['string','null'],enum=[None,*recent])))
    topic=object_schema(dict(key=text,title=text,summary=text,event_keys=dict(type='array',items=text,minItems=2),existing_topic_id=dict(type=['string','null'],enum=[None,*topics])))
    allocations=object_schema({d['id']:object_schema({str(s['id']):text for s in d['source_spans']}) for d in context['new_sources']})
    return object_schema(dict(state=state,issues=dict(type='array',items=issue),topics=dict(type='array',items=topic),allocations=allocations))
