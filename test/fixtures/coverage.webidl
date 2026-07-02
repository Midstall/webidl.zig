// coverage.webidl: exercises hard emitter cases

enum WithEmpty { "", "value" };

interface WithType {
  attribute DOMString type;
};

interface WithPromise {
  Promise<long> doAsync();
};

interface WithBigint {
  attribute bigint bigNum;
};

interface WithNullable {
  undefined takeNullable(long? x);
};

interface WithVariadic {
  undefined takeVariadic(long... xs);
};

interface WithConstructor {
  constructor(long x, long y);
  undefined doThing();
};

interface WithStatic {
  static undefined staticOp(long x);
  static readonly attribute long staticVal;
};

interface WithGetter {
  getter DOMString (unsigned long index);
};

namespace MathNS {
  double sqrt(double x);
};
