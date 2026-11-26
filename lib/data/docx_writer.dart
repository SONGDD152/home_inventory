import 'dart:convert';
import 'dart:typed_data';

/// V4.0：最小可用的 `.docx` 生成器（**零新增依赖**）。
///
/// 为什么不用 `docx` 包：本次构建环境的 pub 镜像**没有 `docx` 这个包**
/// （`pub.flutter-io.cn/api/packages/docx` 返回 404，已核实），
/// 而 `docx_creator` 之类的替代包会拖进 image/html/http 等一串依赖，
/// 白增构建面。
///
/// 自己写反而更稳：**不引任何原生插件、不碰 compileSdk 冲突区**，
/// 出包四道锁里的「release 构建验 checkReleaseAarMetadata」风险直接归零。
///
/// 产出的 `.docx` 是标准 OOXML 包（ZIP + XML），
/// Word / WPS 可直接打开、编辑（本项目的测试会解压校验结构与文本）。
///
/// V4.1 批次 2：正文行（可标红）。
///
/// 元宝 B6：「未完成：提示框内未处理的条目，**标红显示**」。
/// Markdown 没有颜色语法，所以 .md 用 `!!` 前缀标记；
/// .docx 走 OOXML 的 `<w:color w:val="FF0000"/>` —— **真红色**。
class DocxLine {
  const DocxLine(this.text, {this.red = false});

  /// 正文文本。
  final String text;

  /// 是否标红（未完成条目）。
  final bool red;
}

/// ZIP 采用 **store（不压缩）** 模式：实现最小、格式合法，
/// 文件略大一点，对日报这种小文档无所谓。
class DocxWriter {
  const DocxWriter._();

  /// 生成一份 docx。
  ///
  /// [title] 是文档标题（一级标题）；[lines] 是正文行。
  static Uint8List build({String? title, List<String> lines = const <String>[]}) {
    return buildLines(
      title: title,
      lines: lines.map((t) => DocxLine(t)).toList(),
    );
  }

  /// 生成一份 docx（支持标红行）。
  static Uint8List buildLines({
    String? title,
    required List<DocxLine> lines,
  }) {
    final entries = <String, List<int>>{
      '[Content_Types].xml': _utf8(_contentTypes()),
      '_rels/.rels': _utf8(_rootRels()),
      'docProps/core.xml': _utf8(_coreProps(title)),
      'word/document.xml': _utf8(_documentXml(title, lines)),
      'word/styles.xml': _utf8(_stylesXml()),
      'word/_rels/document.xml.rels': _utf8(_documentRels()),
    };
    return _zip(entries);
  }

  static List<int> _utf8(String text) => utf8.encode(text);

  // ---------- OOXML 片段 ----------

  static String _contentTypes() => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
</Types>
''';

  static String _rootRels() => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
</Relationships>
''';

  static String _documentRels() => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>
''';

  static String _coreProps(String? title) => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <dc:title>${_escapeXml(title ?? '日报')}</dc:title>
  <dc:creator>家庭仓储</dc:creator>
</cp:coreProperties>
''';

  static String _stylesXml() => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:docDefaults>
    <w:rPrDefault>
      <w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="宋体"/><w:sz w:val="22"/></w:rPr>
    </w:rPrDefault>
  </w:docDefaults>
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
    <w:name w:val="Normal"/><w:qFormat/>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading1">
    <w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
    <w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr>
    <w:rPr><w:b/><w:sz w:val="32"/></w:rPr>
  </w:style>
</w:styles>
''';

  static String _documentXml(String? title, List<DocxLine> lines) {
    final buffer = StringBuffer();
    buffer.write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
    buffer.write(
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">');
    buffer.write('<w:body>');
    if (title != null && title.isNotEmpty) {
      buffer.write('<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
          '<w:r><w:t xml:space="preserve">${_escapeXml(title)}</w:t></w:r></w:p>');
    }
    for (final line in lines) {
      // 标红：走 OOXML 的 run properties（真红色，Word / WPS 都能显示）。
      final runProps =
          line.red ? '<w:rPr><w:color w:val="FF0000"/><w:b/></w:rPr>' : '';
      buffer.write('<w:p><w:r>$runProps'
          '<w:t xml:space="preserve">${_escapeXml(line.text)}</w:t></w:r></w:p>');
    }
    buffer.write('<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" '
        'w:header="851" w:footer="992" w:gutter="0"/></w:sectPr>');
    buffer.write('</w:body></w:document>');
    return buffer.toString();
  }

  /// XML 文本转义（`&`、`<`、`>`、`"`）。
  static String _escapeXml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  // ---------- ZIP（store 模式） ----------

  static Uint8List _zip(Map<String, List<int>> entries) {
    final out = BytesBuilder(copy: false);
    final central = BytesBuilder(copy: false);
    var offset = 0;

    for (final entry in entries.entries) {
      final nameBytes = utf8.encode(entry.key);
      final data = entry.value;
      final crc = _crc32(data);

      // Local file header
      final header = BytesBuilder(copy: false);
      header.add(<int>[0x50, 0x4B, 0x03, 0x04]); // PK\x03\x04
      header.add(<int>[0x14, 0x00]); // version needed: 2.0
      header.add(<int>[0x00, 0x00]); // flags
      header.add(<int>[0x00, 0x00]); // method: store
      header.add(<int>[0x00, 0x00]); // mod time
      header.add(<int>[0x21, 0x00]); // mod date（固定值，保证同内容同字节）
      header.add(_uint32(crc));
      header.add(_uint32(data.length)); // compressed size
      header.add(_uint32(data.length)); // uncompressed size
      header.add(_uint16(nameBytes.length));
      header.add(_uint16(0)); // extra length
      header.add(nameBytes);

      // Central directory entry
      final centralEntry = BytesBuilder(copy: false);
      centralEntry.add(<int>[0x50, 0x4B, 0x01, 0x02]); // PK\x01\x02
      centralEntry.add(<int>[0x14, 0x00]); // version made by
      centralEntry.add(<int>[0x14, 0x00]); // version needed
      centralEntry.add(<int>[0x00, 0x00]); // flags
      centralEntry.add(<int>[0x00, 0x00]); // method: store
      centralEntry.add(<int>[0x00, 0x00]); // mod time
      centralEntry.add(<int>[0x21, 0x00]); // mod date
      centralEntry.add(_uint32(crc));
      centralEntry.add(_uint32(data.length));
      centralEntry.add(_uint32(data.length));
      centralEntry.add(_uint16(nameBytes.length));
      centralEntry.add(_uint16(0)); // extra
      centralEntry.add(_uint16(0)); // comment
      centralEntry.add(_uint16(0)); // disk number
      centralEntry.add(_uint16(0)); // internal attrs
      centralEntry.add(_uint32(0)); // external attrs
      centralEntry.add(_uint32(offset)); // relative offset
      centralEntry.add(nameBytes);

      out.add(header.toBytes());
      out.add(data);
      central.add(centralEntry.toBytes());
      offset += header.length + data.length;
    }

    final centralBytes = central.toBytes();
    final end = BytesBuilder(copy: false);
    end.add(<int>[0x50, 0x4B, 0x05, 0x06]); // PK\x05\x06
    end.add(<int>[0x00, 0x00]); // disk number
    end.add(<int>[0x00, 0x00]); // disk with central dir
    end.add(_uint16(entries.length));
    end.add(_uint16(entries.length));
    end.add(_uint32(centralBytes.length));
    end.add(_uint32(offset));
    end.add(<int>[0x00, 0x00]); // comment length

    out.add(centralBytes);
    out.add(end.toBytes());
    return out.toBytes();
  }

  static List<int> _uint16(int value) => <int>[
        value & 0xFF,
        (value >> 8) & 0xFF,
      ];

  static List<int> _uint32(int value) => <int>[
        value & 0xFF,
        (value >> 8) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 24) & 0xFF,
      ];

  /// CRC-32（IEEE 802.3，ZIP 标准算法）。
  static int _crc32(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static final List<int> _crcTable = _buildCrcTable();

  static List<int> _buildCrcTable() {
    final table = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      table[i] = c;
    }
    return table;
  }
}
