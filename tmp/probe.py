import importlib.util, time
spec = importlib.util.spec_from_file_location("r", "shell/session-reaper.py"); r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)
t=time.time()
r.batch_issue_states([("theQuert/stima-api","6477"),("theQuert/stima-api","6679"),("theQuert/stima-api","99999999"),("theQuert/stima-api","4449")])
print(r._issue_cache, round(time.time()-t,1))
import subprocess
for n in ("6477","6679","4449"):
    print(n, subprocess.run(["gh","issue","view",n,"-R","theQuert/stima-api","--json","state","-q",".state"],capture_output=True,text=True).stdout.strip())
