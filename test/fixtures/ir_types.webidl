// ir_types.webidl: IR-only fixture covering type/literal variants not in minimal or coverage.

// callback: exercises the Callback model node.
callback OnProgress = undefined (DOMString message, double progress);

// dictionary with defaults covering: boolean true, boolean false, decimal, string, Infinity, -Infinity, NaN.
dictionary LiteralDefaults {
  boolean flagTrue = true;
  boolean flagFalse = false;
  double rate = 1.5;
  DOMString label = "hello";
  double posInf = Infinity;
  double negInf = -Infinity;
  double notANumber = NaN;
};

// interface exercising buffer, union, record, FrozenArray, ObservableArray, named type.
interface TypeCoverage {
  attribute ArrayBuffer buf;
  attribute FrozenArray<long> frozen;
  attribute ObservableArray<long> observable;
  attribute OnProgress handler;
  record<DOMString, long> getMapping();
  undefined takeUnion((long or DOMString) value);
};
