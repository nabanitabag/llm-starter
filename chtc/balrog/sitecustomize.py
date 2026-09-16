import os
import getpass
import pwd

# Fetch the user from the environment (defaulting to 'chtc_user' as a safe fallback)
user = os.environ.get("CHTC_USER", "chtc_user")

# 1. Force environment variables
os.environ["USER"] = user
os.environ["LOGNAME"] = user
os.environ["HOME"] = "/tmp"

# 2. Monkeypatch getpass module
def getuser():
    return user
getpass.getuser = getuser

# 3. Monkeypatch pwd module
orig_getpwuid = pwd.getpwuid
def fake_getpwuid(uid):
    try:
        return orig_getpwuid(uid)
    except KeyError:
        return (user, 'x', uid, 1000, 'CHTC User', "/tmp", '/bin/bash')
pwd.getpwuid = fake_getpwuid