xquery version "3.0";

import module namespace xmdl="http://lagua.nl/lib/xmdl";

let $dataroot := "/db/data"
let $domain := "xmdl-test"

return xmdl:request($dataroot,$domain)
