"""CPU acoustic inference using the pinned sherpa-onnx APIs; no ASR/network I/O."""
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import time
import numpy as np
import sherpa_onnx


def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for data in iter(lambda:f.read(1024*1024),b''):h.update(data)
    return h.hexdigest()


class AcousticEngine:
    version='xinlika-sherpa-worker-v1'
    def __init__(self,models):
        models=Path(models);tagging=models/'sherpa-onnx-zipformer-small-audio-tagging-2024-04-15'
        paths=[models/'silero_vad.onnx',models/'wespeaker_zh_cnceleb_resnet34.onnx',tagging/'model.int8.onnx',tagging/'class_labels_indices.csv']
        self.models=[{'name':p.name,'sha256':digest(p)} for p in paths]
        self.profile=hashlib.sha256((self.version+str(self.models)).encode()).hexdigest()
        self.speaker_hash=self.models[1]['sha256']
        self.vad_config=sherpa_onnx.VadModelConfig();self.vad_config.silero_vad.model=str(paths[0])
        self.vad_config.silero_vad.min_speech_duration=.3;self.vad_config.silero_vad.min_silence_duration=.5;self.vad_config.sample_rate=16000
        config=sherpa_onnx.AudioTaggingConfig(model=sherpa_onnx.AudioTaggingModelConfig(
            zipformer=sherpa_onnx.OfflineZipformerAudioTaggingModelConfig(model=str(paths[2])),num_threads=1,provider='cpu'),labels=str(paths[3]),top_k=8)
        if not config.validate():raise ValueError('Invalid tagging configuration')
        self.tagger=sherpa_onnx.AudioTagging(config)
        self.speaker=sherpa_onnx.SpeakerEmbeddingExtractor(sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(paths[1]),num_threads=1,provider='cpu'))
        spec=importlib.util.spec_from_file_location('acoustic_cb08_codec',Path(__file__).with_name('analyze-cb08-capture.py'))
        self.codec=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.codec)

    def analyze(self,path,expected_hash=None):
        begun=time.monotonic();path=Path(path);source_hash=digest(path)
        if expected_hash and source_hash!=expected_hash:raise ValueError('Original acoustic audio hash changed')
        raw_size=path.stat().st_size
        if not 0<raw_size<=600000 or raw_size%40:raise ValueError('Only sealed <=300 second CB08 batches accepted')
        with tempfile.TemporaryDirectory(prefix='xinlika-acoustic-') as folder:
            ogg=Path(folder)/'source.ogg';self.codec.wrap_cb08(path,ogg)
            result=subprocess.run(['ffmpeg','-nostdin','-v','error','-xerror','-i',str(ogg),'-ar','16000','-ac','1','-f','f32le','pipe:1'],check=True,capture_output=True,timeout=30)
        samples=np.frombuffer(result.stdout,dtype=np.float32).copy();rate=16000;seconds=len(samples)/rate
        if not len(samples) or seconds>raw_size/2000+1e-6:raise ValueError('Decoded audio length does not match canonical packet clock')
        vad=sherpa_onnx.VoiceActivityDetector(self.vad_config,buffer_size_in_seconds=310)
        for i in range(0,len(samples),self.vad_config.silero_vad.window_size):vad.accept_waveform(samples[i:i+self.vad_config.silero_vad.window_size])
        vad.flush();speech=[]
        while not vad.empty():
            segment=vad.front;begin=max(0,segment.start);end=min(len(samples),begin+len(segment.samples))
            if end>begin:speech.append((begin,samples[begin:end].copy()))
            vad.pop()
        scenes=[]
        for i in range(0,len(samples),rate*10):
            part=samples[i:i+rate*10]
            if len(part)<rate:continue
            stream=self.tagger.create_stream();stream.accept_waveform(sample_rate=rate,waveform=part)
            tags=self.tagger.compute(stream)
            scenes.append({'start_seconds':i/rate,'end_seconds':(i+len(part))/rate,
                'tags':[{'name':r.name,'score':float(r.prob),'index':r.index} for r in tags],
                'source_medium':'unknown','user_identity':'unknown'})
        vectors=[];windows=[];centres=[]
        for begin,data in speech:
            for i in range(0,len(data),rate*5):
                part=data[i:i+rate*5]
                if len(part)<rate*2:continue
                stream=self.speaker.create_stream();stream.accept_waveform(sample_rate=rate,waveform=part);stream.input_finished()
                if not self.speaker.is_ready(stream):continue
                vector=np.asarray(self.speaker.compute(stream),dtype=np.float32);vector/=max(float(np.linalg.norm(vector)),1e-9)
                scores=[float(np.dot(vector,c)) for c in centres];best=int(np.argmax(scores)) if scores else -1
                if best<0 or scores[best]<.6:best=len(centres);centres.append(vector.copy())
                windows.append({'start_seconds':(begin+i)/rate,'end_seconds':(begin+i+len(part))/rate,
                    'anonymous_cluster':f'speaker_{best+1}','best_similarity_before_assignment':max(scores) if scores else None,
                    'user_identity':'not_enrolled','boundary_precision':'coarse_5s_window_not_verified_turn'})
                vectors.append(vector.tolist())
        observation={'source_sha256':source_hash,'source_format':'raw_cb08_40','producer_version':self.version,
            'selection':{'start':0,'duration':seconds},'models':self.models,
            'speech_intervals':[{'start_seconds':b/rate,'end_seconds':(b+len(v))/rate} for b,v in speech],
            'scene_windows':scenes,'speaker_windows':windows,'anonymous_clusters':len(centres),
            'model_elapsed_seconds':time.monotonic()-begun,'enrollment_present':False,'asr_called':False,
            'limits':['Acoustic hints are uncalibrated','Live playback remains ambiguous','Anonymous clusters are not verified turn diarization','No personal experience inferred']}
        return {'observation':observation,'vectors':vectors,'speech_seconds':sum(len(v) for _,v in speech)/rate,
            'clipped_fraction':float(np.mean(np.abs(samples)>=.999))}
