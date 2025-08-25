# -*- coding: utf-8 -*-
from __future__ import (absolute_import, division, print_function)
__metaclass__ = type

DOCUMENTATION = r'''
lookup: gl_latest_version
author: Validatrium
version_added: "1.0.0"
short_description: Resolve the latest GenLayer node version from GCS
description:
  - Queries Google Cloud Storage endpoint for available GenLayer versions and returns the latest (sorted descending).
options: {}
'''

EXAMPLES = r'''
- name: Resolve latest version
  set_fact:
    latest: "{{ lookup('validatrium.genlayer.gl_latest_version') }}"
'''

RETURN = r'''
_raw:
  description:
    - Latest version string like C(v0.3.10)
  type: str
'''

from ansible.plugins.lookup import LookupBase
from ansible.errors import AnsibleError
try:
    # Python stdlib
    from urllib.request import urlopen
except Exception:
    from urllib2 import urlopen  # type: ignore
import re

URL = "https://storage.googleapis.com/storage/v1/b/gh-af/o?prefix=genlayer-node/bin/amd64"

class LookupModule(LookupBase):
    def run(self, terms, variables=None, **kwargs):
        try:
            with urlopen(URL, timeout=15) as resp:
                data = resp.read().decode('utf-8', errors='ignore')
        except Exception as e:
            raise AnsibleError("Failed to fetch versions: %s" % (e,))

        names = re.findall(r'"name":\s*"([^"]+)"', data)
        versions = []
        for n in names:
            m = re.search(r'/(v[^/]+)/', n)
            if m:
                versions.append(m.group(1))
        if not versions:
            raise AnsibleError("No versions found in GCS listing.")

        def ver_key(v):
            core = v[1:]
            parts = re.split(r'[\.-]', core)
            key = []
            for p in parts:
                try:
                    key.append(int(p))
                except ValueError:
                    key.append(p)
            return key
        versions = sorted(set(versions), key=ver_key, reverse=True)
        return [versions[0]]
