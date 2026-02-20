import os
import getpass
import pwd
from dotenv import load_dotenv

load_dotenv()

# 1. Force environment variables
os.environ["USER"] = os.environ.get("USERNAME", "nbag")
os.environ["LOGNAME"] = os.environ.get("USERNAME", "nbag")
os.environ["HOME"] = "/tmp"

# 2. Monkeypatch getpass module
def getuser():
    return os.environ.get("USERNAME", "nbag")
getpass.getuser = getuser

# 3. Monkeypatch pwd module (This is exactly where your error is coming from!)
# The error "getpwuid(): uid not found" happens here. We intercept it.
orig_getpwuid = pwd.getpwuid
def fake_getpwuid(uid):
    try:
        return orig_getpwuid(uid)
    except KeyError:
        # Return a fake struct_passwd tuple if the real one fails
        # Format: (name, password, uid, gid, gecos, dir, shell)
        return (os.environ.get("USERNAME", "nbag"), 'x', uid, 1000, 'CHTC User', "/tmp", '/bin/bash')
pwd.getpwuid = fake_getpwuid