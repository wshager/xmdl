xquery version "3.0";

(:
 * This module provides model-based querying for XML
 :)

module namespace xmdl="http://lagua.nl/lib/xmdl";

declare namespace request="http://exist-db.org/xquery/request";
declare namespace response="http://exist-db.org/xquery/response";

import module namespace json="http://www.json.org";
import module namespace xmldb="http://exist-db.org/xquery/xmldb";
import module namespace xqjson="http://xqilla.sourceforge.net/lib/xqjson";
import module namespace xrql="http://lagua.nl/lib/xrql";

(:
Transform into xml serializable to json natively by eXist
:)

declare function xmdl:to-plain-xml($node as element()) as element()* {
	let $name := string(node-name($node))
	let $name :=
		if($name = "json") then
			"root"
		else if($name = "pair" and $node/@name) then
			$node/@name
		else
			$name
	return
		if($node[@type = "array"]) then
			for $item in $node/node() return
				let $item := element {$name} {
					attribute {"json:array"} {"true"},
						$item/node()
					}
					return xmdl:to-plain-xml($item)
		else
			element {$name} {
				if($node/@type = ("number","boolean")) then
					attribute {"json:literal"} {"true"}
				else
					(),
				$node/@*[matches(name(.),"json:")],
				for $child in $node/node() return
					if($child instance of element()) then
						xmdl:to-plain-xml($child)
					else
						$child
			}
};

declare function xmdl:check-html($node,$accept) {
	if(exists($node) and matches($accept,"application/[json|javascript]")) then
		element { name($node) } {
			$node/@*,
			for $x in $node/* return
				if($x/body) then
					element { name($x) } { util:serialize($x/body,"method=html media-type=text/html") }
				else
					$x
		}
	else
		$node 
};

declare function xmdl:resolve-links($node as element(), $schema as element()?, $store as xs:string) as element() {
	if($schema) then
		element root {
			$node/node(),
			for $l in $schema/links return
				let $href := tokenize($l/href,"\?")
				let $uri := $href[1]
				let $qstr := $href[2]
				let $qstr := string-join(
					for $x in analyze-string($qstr, "\{([^}]*)\}")/* return
						if(local-name($x) eq "non-match") then
							$x
						else
							for $g in $x/fn:group
								return $node/*[local-name() eq $g]
				)
				return
					if($l/resolution eq "lazy") then
						element { $l/rel } {
							element { "_ref" } { $uri || "?" || $qstr }
						}
					else
						let $q := xrql:parse($qstr,())
						return element { $l/rel } {
							for $x in xrql:sequence(collection(resolve-uri($uri,$store || "/"))/root,$q,500,false()) return
								element {"json:value"} {
									attribute {"json:array"} {"true"},
									$x/node()
								}
						}
		}
	else
		$node
};

(: fill in defaults, infer types :)
(: TODO basic validation :)
declare function xmdl:from-schema($node as element(), $schema as element()?) {
    if($schema) then
        let $props := for $p in $node/* return name($p)
        let $defaults :=
            for $p in $schema/properties/* return
                if(name($p) = $props) then
                    ()
                else
                    if($p/default) then
                        element { name($p) } {
                            if($p/type eq "string") then
                                ()
                            else
                                attribute { "json:literal"} { "true" },
                            if($p/type eq "string" and $p/format eq "date-time" and $p/default eq "now()") then
                                current-dateTime()
                            else
                                $p/default/text()
                        }
                    else
                        ()
        let $props := for $p in $schema/properties/* return name($p)
        let $data := for $p in $node/* return
            if(name($p) = $props) then
                let $s := $schema/properties/*[name(.) = name($p)]
                return
                    if($s/type = "string") then
                        $p
                    else
                        element { name($p) } {
                            attribute {"json:literal"} { "true" },
                            $p/text()
                        }
            else
                $p
        return element { name ($node) } {
            $data,
            $defaults
        }
    else
        $node
};

(: writes increment value to schema :)
declare function xmdl:get-next-id($schema as element()?,$schemastore as xs:string,$schemaname as xs:string) {
    if($schema) then
        let $key := $schema/properties/*[primary and auto_increment]
        let $id := 
            if($key) then
                string($key/auto_increment)
            else
                ()
        let $null :=
            if($key) then
                let $schema :=
                    element root {
                        $schema/@*,
                        element properties {
                            for $p in $schema/properties/* return
                                if($p=$key) then
                                    element {name($p)} {
                                        $p/@*,
                                        $p/*[name(.) != "auto_increment"],
                                        element auto_increment {
                                            $p/auto_increment/@*,
                                            number($p/auto_increment) + 1
                                        }
                                    }
                                else
                                    $p
                        },
                        $schema/*[name(.) != "properties"]
                    }
                return xmldb:store($schemastore,$schemaname,$schema)
            else
                ()
        return $id
    else
        ()
};

declare function xmdl:request() {
	let $dataroot := "/db/data"
	return xmdl:request($dataroot)
};

declare function xmdl:request($dataroot as xs:string) {
	let $domain := request:get-server-name()
	return xmdl:request($dataroot,$domain)
};

declare function xmdl:request($dataroot as xs:string,$domain as xs:string) {
	let $model := request:get-parameter("model","")
	return xmdl:request($dataroot,$domain,$model)
};

declare function xmdl:request($dataroot as xs:string,$domain as xs:string,$model as xs:string) {
	let $accept := request:get-header("Accept")
	let $method := request:get-method()
	let $id := request:get-parameter("id","")
	let $qstr := string(request:get-query-string())
	return xmdl:request($dataroot,$domain,$model,$id[1],$method,$accept,$qstr)
};

declare function xmdl:request($dataroot as xs:string, $domain as xs:string,$model as xs:string,$id as xs:string,$method as xs:string,$accept as xs:string,$qstr as xs:string) {
	let $data := 
		if($method = ("PUT","POST")) then
			util:binary-to-string(request:get-data())
		else
			""
	return xmdl:request($dataroot,$domain,$model,$id,$method,$accept,$qstr,$data)
};

declare function xmdl:request($dataroot as xs:string, $domain as xs:string,$model as xs:string,$id as xs:string,$method as xs:string,$accept as xs:string,$qstr as xs:string,$data as xs:string) {
	let $maxLimit := 100
	let $root := $dataroot || "/" || $domain || "/model/"
	let $store :=  $root || $model
	let $schemastore := $root || "Class"
	(: use model as default schema for now :)
	let $schemaname := $model || ".xml"
	let $schemadoc := $schemastore || "/" || $schemaname
	let $schema :=
		if(doc-available($schemadoc)) then
			doc($schemadoc)/root
		else
			()
	let $maxLimit :=
		if($schema/maxCount) then
			number($schema/maxCount)
		else
			$maxLimit
	let $null :=
		if(matches($accept,"application/[json|javascript]")) then
			util:declare-option("exist:serialize", "method=json media-type=application/json")
		else if(matches($accept,"[text|application]/xml")) then
			util:declare-option("exist:serialize", "method=xml media-type=application/xml")
		else if(matches($accept,"text/html")) then
			util:declare-option("exist:serialize", "method=html media-type=text/html")
		else
			()
	return
		if($model eq "") then
			response:set-status-code(500)
		else if($method = ("PUT","POST")) then
			let $data := 
				if($data != "") then
					$data
				else
					"{}"
			let $xml := xqjson:parse-json($data)
			let $xml := xmdl:to-plain-xml($xml)
			let $did := $xml/id/text()
			(: check if id in data:
			this will take precedence, and actually move a resource 
			from the original ID if that ID differs
			:)
			let $oldId := 
				if($did and $id and $did != $id) then
					$id
				else
					""
			let $id :=
				if($did) then
					$did
				else if($id) then
					$id
				else
				    let $next-id := xmdl:get-next-id($schema,$schemastore,$model || ".xml")
				    return
	    			    if($next-id) then
				            $next-id
				        else
					        util:uuid()
			let $xml := 
				if($did) then
				   $xml
				else
					element {"root"} {
						$xml/@*,
						$xml/*[name(.) != "id"],
						element id {
							$id
						}
					}
			let $xml := xmdl:from-schema($xml,$schema)
			let $doc :=
				if(exists(collection($store)/root[id = $id])) then
					base-uri(collection($store)/root[id = $id])
				else
					$id || ".xml"
			let $res := xmldb:store($store, $doc, $xml)
			return
				if($res) then
					$xml
				else
					response:set-status-code(500)
		else if($method="GET") then
			if($id != "") then
				let $res := xmdl:check-html(collection($store)/root[id = $id],$accept)
				return
					if($res) then
						$res
					else
						(element root {
							"Error: " || $model || "/" || $id || " not found"
						},
						response:set-status-code(404))
			else if($qstr ne "" or request:get-header("range") or sm:is-authenticated()) then
				let $q := xrql:parse($qstr,())
				let $res := for $x in xrql:sequence(collection($store)/root,$q,$maxLimit) return
					xmdl:check-html(element {"json:value"} {
						attribute {"json:array"} {"true"},
						xmdl:resolve-links($x,$schema,$store)/node()
					},$accept)
				return
					if($res) then
						element root { $res	}
					else
						<root json:literal="true">[]</root>
			else
				(element root {
					"Error: Guests are not allowed to query the entire collection"
				},
				response:set-status-code(403))
		else if($method="DELETE") then
			if($id != "") then
				let $path := base-uri(collection($store)/root[id = $id])
				let $parts := tokenize($path,"/")
				let $doc := $parts[last()]
				let $parts := remove($parts,last())
				let $path  := string-join($parts,"/")
				return xmldb:remove($path, $doc)
			else
				response:set-status-code(500)
		else
			response:set-status-code(500)
};