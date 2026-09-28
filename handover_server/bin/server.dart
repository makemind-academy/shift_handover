import 'dart:async';
import 'dart:convert';

import 'package:mcp_server/mcp_server.dart';

import 'serve_bundle.dart';

/// handover_server — what the leaving shift tells the arriving shift.
///
/// The failure this is built against is not forgetting. It is the item that
/// gets mentioned every handover for a week and never gets done, because each
/// shift assumes the one before it looked into it.
///
/// So an item that is not closed does not get re-typed by the next shift. It
/// is carried, and the carry is counted. An item on its fourth shift says so
/// on the screen, and that number is the one thing a supervisor actually needs
/// to see.
void main(List<String> args) async {
  const config = McpServerConfig(
    name: 'Shift Handover',
    version: '1.0.0',
    capabilities: ServerCapabilities(
      tools: ToolsCapability(listChanged: true),
      resources: ResourcesCapability(listChanged: true),
    ),
  );
  final server = McpServer.createServer(config);
  HandoverServer(server).register();
  // The screen next door: AppPlayer reads it from here and sends the pages'
  // tool calls back to the tools above.
  registerBundleUi(server, '../handover.mbd');
  final transport = McpServer.createStdioTransport().get();
  server.connect(transport);
  await Completer<void>().future;
}

/// One thing the next shift needs to know.
class Item {
  Item(this.id, this.raisedBy, this.raisedOnShift, this.text);

  final int id;
  final String raisedBy;
  final int raisedOnShift;
  final String text;

  /// How it was closed, if it was. Empty means still open.
  String closedNote = '';
  String? closedBy;
}

class HandoverServer {
  HandoverServer(this.server);

  final Server server;

  static const _crew = ['Night', 'Morning', 'Afternoon', 'Night', 'Morning'];

  int _shift = 0;
  int _nextId = 1;
  // The night shift has already written three things down when the board opens.
  late final _items = <Item>[
    Item(_nextId++, 'Night', 0, 'Chiller 2 running warm'),
    Item(_nextId++, 'Night', 0, 'Card reader at lane 3 rebooting'),
    Item(_nextId++, 'Night', 0, 'Bread delivery short by 6'),
  ];

  void register() {
    server.addTool(
      name: 'shift.state',
      description: 'What is open, and how long each thing has been open',
      inputSchema: const {'type': 'object', 'properties': {}},
      handler: (args) async => _state(),
    );

    server.addTool(
      name: 'shift.raise',
      description: 'Write something the next shift needs to know',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
        'required': ['text'],
      },
      handler: (args) async {
        final item = Item(_nextId++, _crew[_shift], _shift, args['text'] as String);
        _items.add(item);
        return _state(notice: '#${item.id} raised by ${item.raisedBy}');
      },
    );

    server.addTool(
      name: 'shift.close',
      description: 'Close an item, with what was actually done',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'note': {'type': 'string'},
        },
        'required': ['id', 'note'],
      },
      handler: (args) async {
        final id = args['id'] as int;
        final item = _items.where((i) => i.id == id).firstOrNull;
        if (item == null) return _state(notice: 'no item #$id');
        // Closing needs a note. "Done" with no note is how an item comes back
        // three days later with nobody able to say what was tried.
        final note = (args['note'] as String).trim();
        if (note.isEmpty) {
          return _state(notice: '#$id needs a note to close');
        }
        item.closedNote = note;
        item.closedBy = _crew[_shift];
        return _state(notice: '#$id closed by ${item.closedBy}');
      },
    );

    server.addTool(
      name: 'shift.handover',
      description: 'End this shift and start the next one',
      inputSchema: const {'type': 'object', 'properties': {}},
      handler: (args) async {
        // Nothing is copied forward and nothing is cleared. The next shift
        // opens the same list. Carrying is the default; closing is the act.
        _shift = (_shift + 1) % _crew.length;
        final open = _items.where((i) => i.closedNote.isEmpty).length;
        return _state(
            notice: '${_crew[_shift]} took over with $open still open');
      },
    );
  }

  CallToolResult _state({String notice = ''}) {
    final open = _items.where((i) => i.closedNote.isEmpty).toList();
    final closed = _items.where((i) => i.closedNote.isNotEmpty).toList();

    // The number that matters. Not stored on the item — an item does not know
    // how many shifts have passed, the shift counter does.
    int carried(Item i) => _shift - i.raisedOnShift;
    // One shift is a handover, two are handovers. A screen that says
    // "1 handovers" is a screen nobody proofread.
    String plural(int n, String one) => "$n $one" + (n == 1 ? "" : "s");

    final worst = open.isEmpty
        ? 0
        : open.map(carried).reduce((a, b) => a > b ? a : b);

    return CallToolResult(content: [
      TextContent(
        text: jsonEncode({
          'crew': _crew[_shift].toUpperCase(),
          // The rule a handover board runs by, printed where both crews see
          // it. Three crossings is the shop's line, not the screen's.
          'handoverRule':
              'An item that crosses 3 handovers is escalated, not handed on',
          'openCount': open.length,
          'rows': [
            for (final i in open)
              {
                'id': '#${i.id}',
                'text': i.text,
                'from': 'raised by ${i.raisedBy}',
                'carried': carried(i) == 0
                    ? 'this shift'
                    : 'carried ${plural(carried(i), "shift")}',
                // Anything that has crossed three handovers is not an open
                // item any more, it is a decision nobody is making.
                'stale': carried(i) >= 3,
              },
          ],
          'worst': worst,
          'worstLabel': plural(worst, 'handover'),
          'worstNote': worst >= 3
              ? 'something has crossed ${plural(worst, "handover")} — nobody is deciding it'
              : 'nothing older than ${plural(worst, "handover")}',
          'closedCount': closed.length,
          'closedLine': closed.isEmpty
              ? 'nothing closed yet'
              : closed
                  .map((i) => '#${i.id} ${i.closedBy}: ${i.closedNote}')
                  .join(' · '),
          'notice': notice,
        }),
      )
    ]);
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
