xquery version "3.0";

import module namespace xmdl="http://lagua.nl/lib/xmdl";

let $domain := "xmdl-test"

return xmdl:request($domain)