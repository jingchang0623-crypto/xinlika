"""Conservative display gate; original speech remains in the audio/text ledger."""
import re


def has_semantic_content(text):
    value=re.sub(r'[\W_]+','',text or '',flags=re.UNICODE).lower()
    # Do not use minimum length: 吃药、喝水、着火、到了 can be useful events.
    if not value:return False
    return value not in {'那个','嗯','啊','哦','噢','呃','额','哎','哎呀','唉','女','男','好','好的','对','对对','是','是的','谢谢','ok','okay','uh','um','ah'} and not re.fullmatch(r'[嗯啊哦噢呃额哎唉]+',value)
