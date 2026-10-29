import importlib.util, sys, time
src = sys.argv[1]
spec = importlib.util.spec_from_file_location("r", src); r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)
r.fcntl.flock = lambda *a, **k: None  # the live run holds the real lock; this run is APPLY=0 and writes only its own report
t = time.time()
rc = r.main(["--config", sys.argv[2]])
print("wall", round(time.time() - t, 1), "s rc", rc)
