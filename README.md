mdl
====

An XQuery module for RESTful models

Models are stored by default in /db/data/domain/model

Please note: this module requires https://github.com/wshager/xrql

Test with eXist:
--------

Download and install eXist 2.x @ http://exist-db.org

Build the package and install into eXist using the manager in the dashboard.

To run the test:

* build the application "xmdl-test" located in test/apps
* install the app into eXist
* create a collection /db/data/xmdl-test/model/Page

To create a new page (using cURL):

curl -X POST http://localhost:8080/exist/apps/xmdl-test/model/Page/ -H 'Accept:application/json' -d '{"name":"test"}'

Point the browser to:

http://localhost:8080/exist/apps/xmdl-test/model/Page/?name=test
