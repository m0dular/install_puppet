function install_puppet::aggregate(ResultSet *$results) {
  deep_merge(
    **$results.map |$res| {
      $res.ok_set.map |$r| {
        $tmp = { $r.target.name => $r.value }
        $tmp
      }.reduce({}) |$memo, $value| { $memo + $value }
    },
    # Include an empty hash in case there is only one entry in **$results
    {}
  )
}
