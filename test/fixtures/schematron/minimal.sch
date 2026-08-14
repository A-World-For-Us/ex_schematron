<schema xmlns="http://purl.oclc.org/dsdl/schematron" queryBinding="xslt2">
  <ns prefix="inv" uri="urn:invoice"/>
  <pattern id="P-USE">
    <rule context="inv:Invoice/inv:ID">
      <assert test="string-length(.) le 10" id="USE-LEN-1">Identifiant trop long : "<value-of select="."/>".</assert>
    </rule>
  </pattern>
</schema>
