# Fork

This is a fork of gaultier/zig-bencode with fixes for Zig 0.10.1. See https://github.com/gaultier/zig-bencode/pull/1.

# Bencode encoder/decoder

[Bencode](https://en.wikipedia.org/wiki/Bencode) is an text encoding format, not too dissimilar from JSON.
This library can encode and decode it, with an API and code close the `std.json` in the Zig standard library.
No other dependencies than the Zig standard library.

## Decode (parse)

`example_decode.zig`:

```zig
const std = @import("std");
const bencode = @import("src/main.zig");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &gpa.allocator;
    var v = try bencode.ValueTree.parse("d3:agei18e4:name3:joee", allocator);
    defer v.deinit();

    if (bencode.mapLookup(v.root.Map, "age")) |age| {
        if (bencode.isInteger(age.*)) std.debug.warn("age={} ", .{age.Integer});
    }

    if (bencode.mapLookup(v.root.Map, "name")) |name| {
        if (bencode.isString(name.*)) std.debug.warn("name={}\n", .{name.String});
    }
}
// Output: age=18 name=joe
```


See also the CLI utility `bencode_to_yaml.zig` and the tests for more details, e.g about errors: `zig test src/main.zig`.

### Try it out

```sh
$ zig run bencode_to_yaml.zig --  <(echo "d3:abci-99e11:hello,world3:foo8:integersli0ei5000ei-1eee")


"abc": -99
"hello,world": "foo"
"integers":
  - 0
  - 5000
  - -1

$ zig run bencode_to_yaml.zig -- ~/Downloads/debian-10.4.0-amd64-netinst.iso.torrent | head


"announce": "http://bttracker.debian.org:6969/announce"
"comment": "\"Debian CD from cdimage.debian.org\""
"creation date": 1589025369
"httpseeds":
  - "https://cdimage.debian.org/cdimage/release/10.4.0//srv/cdbuilder.debian.org/dst/deb-cd/weekly-builds/amd64/iso-cd/debian-10.4.0-amd64-netinst.iso"
  - "https://cdimage.debian.org/cdimage/archive/10.4.0//srv/cdbuilder.debian.org/dst/deb-cd/weekly-builds/amd64/iso-cd/debian-10.4.0-amd64-netinst.iso"
"info":
  "length": 352321536
  "name": "debian-10.4.0-amd64-netinst.iso"
```

## Encode (stringify)

`example_encode.zig`:

```zig
const Person = struct {
    age: usize,
    name: []const u8,
};
const person = Person{ .age = 18, .name = "joe" };
try bencode.stringify(person, std.io.getStdOut().writer());
// Output: d3:agei18e4:name3:joee
```

## License
BSD-3
