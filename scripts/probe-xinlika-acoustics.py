#!/usr/bin/env python3
"""Local-only acoustic probe using sherpa-onnx models; no ASR or hardware access.

VAD is not speaker identity, speaker similarity is not source-medium detection,
and audio event scores are not calibrated probabilities of user activities.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

import numpy as np
import sherpa_onnx


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()


def analyze(audio,models,output,start=0,seconds=120,cb08=False):
    output.mkdir(parents=True,exist_ok=False,mode=0o700)
    original=audio
    if cb08:
        spec=importlib.util.spec_from_file_location('cb08_codec',Path(__file__).with_name('analyze-cb08-capture.py'))
        codec=importlib.util.module_from_spec(spec);spec.loader.exec_module(codec)
        audio=output/'selected-source.ogg';codec.wrap_cb08(original,audio);audio.chmod(0o600)
    decoded=subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-ss',str(start),'-i',str(audio),'-t',str(seconds),'-ar','16000','-ac','1','-f','f32le','pipe:1'],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    samples=np.frombuffer(decoded.stdout,dtype=np.float32).copy();rate=16000
    if not len(samples):raise ValueError('Selected audio has no samples')
    config=sherpa_onnx.VadModelConfig();config.silero_vad.model=str(models/'silero_vad.onnx')
    config.silero_vad.min_speech_duration=.3;config.silero_vad.min_silence_duration=.5;config.sample_rate=rate
    vad=sherpa_onnx.VoiceActivityDetector(config,buffer_size_in_seconds=seconds+10)
    window=config.silero_vad.window_size
    for pos in range(0,len(samples),window):vad.accept_waveform(samples[pos:pos+window])
    vad.flush();speech=[]
    while not vad.empty():
        segment=vad.front;speech.append((segment.start,np.asarray(segment.samples).copy()));vad.pop()
    tagging=models/'sherpa-onnx-zipformer-small-audio-tagging-2024-04-15'
    tag_config=sherpa_onnx.AudioTaggingConfig(model=sherpa_onnx.AudioTaggingModelConfig(
        zipformer=sherpa_onnx.OfflineZipformerAudioTaggingModelConfig(model=str(tagging/'model.int8.onnx')),
        num_threads=1,provider='cpu',debug=False),labels=str(tagging/'class_labels_indices.csv'),top_k=8)
    if not tag_config.validate():raise ValueError('Invalid tagging model configuration')
    tagger=sherpa_onnx.AudioTagging(tag_config);scenes=[];begun=time.monotonic()
    for pos in range(0,len(samples),rate*10):
        part=samples[pos:pos+rate*10]
        if len(part)<rate:continue
        stream=tagger.create_stream();stream.accept_waveform(sample_rate=rate,waveform=part)
        tags=tagger.compute(stream)
        scenes.append({'start_seconds':start+pos/rate,'end_seconds':start+(pos+len(part))/rate,
            'tags':[{'name':r.name,'score':float(r.prob),'index':r.index} for r in tags],
            'source_medium':'unknown','user_identity':'unknown'})
    embedding_model=models/'wespeaker_zh_cnceleb_resnet34.onnx'
    extractor=sherpa_onnx.SpeakerEmbeddingExtractor(sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(embedding_model),num_threads=1,provider='cpu'))
    centroids=[];speakers=[];embeddings=[]
    for offset,segment in speech:
        # Coarse windows, not overlap-aware turn diarization. Never label as user.
        for pos in range(0,len(segment),rate*5):
            part=segment[pos:pos+rate*5]
            if len(part)<rate*2:continue
            stream=extractor.create_stream();stream.accept_waveform(sample_rate=rate,waveform=part);stream.input_finished()
            if not extractor.is_ready(stream):continue
            vector=np.asarray(extractor.compute(stream),dtype=np.float32);vector/=max(np.linalg.norm(vector),1e-9)
            scores=[float(np.dot(vector,c)) for c in centroids];best=int(np.argmax(scores)) if scores else -1
            if best<0 or scores[best]<.6:best=len(centroids);centroids.append(vector.copy())
            # An example threshold, deliberately not presented as field-calibrated.
            speakers.append({'start_seconds':start+(offset+pos)/rate,'end_seconds':start+(offset+pos+len(part))/rate,
                'anonymous_cluster':f'speaker_{best+1}','best_similarity_before_assignment':max(scores) if scores else None,
                'user_identity':'not_enrolled','boundary_precision':'coarse_5s_window_not_verified_turn'})
            embeddings.append(vector)
    if embeddings:
        path=output/'anonymous-embeddings.npz';np.savez_compressed(path,embeddings=np.asarray(embeddings));path.chmod(0o600)
    paths=[models/'silero_vad.onnx',embedding_model,tagging/'model.int8.onnx',tagging/'class_labels_indices.csv']
    result={'source_sha256':sha(original),'source_format':'raw_cb08_40' if cb08 else 'decoded_media',
        'producer_version':'xinlika-sherpa-probe-v1','selection':{'start':start,'duration':len(samples)/rate},
        'models':[{'name':p.name,'sha256':sha(p)} for p in paths],
        'speech_intervals':[{'start_seconds':start+a/rate,'end_seconds':start+(a+len(b))/rate} for a,b in speech],
        'scene_windows':scenes,'speaker_windows':speakers,'anonymous_clusters':len(centroids),
        'model_elapsed_seconds':time.monotonic()-begun,'enrollment_present':False,'asr_called':False,
        'limits':['No user identity inferred','Playback vs live meeting remains unknown','5s clusters are not validated diarization','Audio tagging scores and similarity threshold require field calibration','No auto-discard or semantic-memory writes']}
    path=output/'result.json';path.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');path.chmod(0o600)
    print(json.dumps({'seconds':len(samples)/rate,'scene_windows':len(scenes),'speech_intervals':len(speech),'anonymous_clusters':len(centroids),'asr_called':False,'user_enrolled':False,'elapsed':result['model_elapsed_seconds']}))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--audio',type=Path,required=True);p.add_argument('--models',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--start',type=float,default=0);p.add_argument('--seconds',type=float,default=120);p.add_argument('--cb08-40',action='store_true');a=p.parse_args()
    if a.start<0 or not 1<=a.seconds<=300:p.error('Explicit selection must be 1–300 seconds')
    analyze(a.audio,a.models,a.output,a.start,a.seconds,a.cb08_40)
