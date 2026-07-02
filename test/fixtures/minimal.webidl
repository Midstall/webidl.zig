enum ReadyState { "connecting", "open", "closed" };

dictionary RequestInit {
  required DOMString method;
  long timeout = 5000;
};

interface EventTarget {
  const unsigned short CONNECTING = 0;
  readonly attribute DOMString url;
  undefined addEventListener(DOMString type);
};
