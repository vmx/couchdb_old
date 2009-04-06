# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License.  You may obtain a copy of
# the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
# License for the specific language governing permissions and limitations under
# the License.

import os
import sys
import random
try:
    import json # python >= 2.6
except ImportError:
    import simplejson as json

class Minimal(object):
    """Process an _external request

    An example for an request would be:
    curl -d '{"design": "designdoc", "view": {"name": "viewname", "query": {"limit": 11}}, "external": {"name": "_externalname", "query": {"q": ""}}}' http://localhost:5984/dbname/_mix

    """
    def __init__(self):
        random.seed(29)

    def wait_for_query(self):
        """Main loop that is waiting for CouchDB external queries"""
        while 1:
            rawinput = sys.stdin.readline()
            
            if rawinput != '':
                self.process_query(json.loads(rawinput))
                sys.stdout.flush()
            else:
                break

    def process_query(self, request):
        rand = random.random()
        if rand < 0.5:
            sys.stdout.write('{"code": 200, "json": true}\n')
        else:
            sys.stdout.write('{"code": 200, "json": false}\n')

def main(args=None):
    m = Minimal()
    m.wait_for_query()

if __name__ == "__main__":
    sys.exit(main())
