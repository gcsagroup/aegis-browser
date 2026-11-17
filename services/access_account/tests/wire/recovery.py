"""Crash the collector during a real forwarded target write, then reconcile its replay."""
import contextlib

from .acceptance import run
from .runtime import Runtime, require, until
from .tls_target import payload


class RestartRuntime(Runtime):
    def launch(self, name, args, **kwargs):
        proc = super().launch(name, args, **kwargs)
        if name == 'collector':
            self.collector_process = proc
            self.collector_args = args
        if name == 'server-xray':
            self.xray_process = proc
            self.xray_args = args
            self.xray_launch = kwargs


def exercise(rt, emit):
    rt.setup()
    with rt.connect('a', plain=True) as stream:
        stream.settimeout(5)
        stream.sendall(payload('p', 0, 32, 'up'))
        require(stream.recv(819) == payload('p', 0, 819, 'down'), 'initial exchange mismatch')
        until(lambda: rt.usage()['uploadedBytes'] == 32 and rt.usage()['downloadedBytes'] == 819)
        rt.collector_process.kill()
        rt.collector_process.wait()
        emit('collector-stopped', rt.usage())
        stream.sendall(payload('p', 1, 32, 'up'))
        # The target has actually consumed the upload while collector acknowledgement is offline.
        until(lambda: rt.plain.received >= 64)
        until(lambda: list(rt.socket_path.with_name(rt.socket_path.name+'.outbox').glob('*.json')))
        with contextlib.suppress(OSError):
            while stream.recv(819):
                pass
        rt.xray_process.terminate()
        rt.xray_process.wait()
        emit('xray-restarted', dict(pendingRecords=len(list(
            rt.socket_path.with_name(rt.socket_path.name+'.outbox').glob('*.json')))))
        rt.launch('server-xray', rt.xray_args, **rt.xray_launch)
        if rt.socket_path.exists():
            rt.socket_path.unlink()
        rt.launch('collector', rt.collector_args, socket_path=rt.socket_path)
        def reconciled():
            state = rt.usage()
            return state if state['uploadedBytes'] == rt.plain.received and state['openFlows'] == 0 else None
        result = until(reconciled)
        require(result['uploadedBytes'] == 64, 'forwarded tail lost after collector restart')
        require(result['downloadedBytes'] <= rt.plain.sent, 'unforwarded target response counted')
        emit('replayed', dict(targetUploaded=rt.plain.received,targetSent=rt.plain.sent,usage=result))


if __name__ == '__main__':
    run(exercise, runtime_class=RestartRuntime)
