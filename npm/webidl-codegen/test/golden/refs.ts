import type { Host } from "@midstall/webidl-runtime";

export class Node {
  constructor(readonly handle: number, private host: Host) {}
  private get obj(): any { return this.host.value(this.handle); }
  static create(host: Host, name: string): Node { return new Node(host.intern(new (globalThis as any)["Node"](name)), host); }
  get parent(): Node | null { return (this.obj.parent === null ? null : new Node(this.host.intern(this.obj.parent), this.host)); }
  set parent(value: Node | null) { this.obj.parent = (value === null ? null : (value as any).obj); }
  appendChild(child: Node): Node { return new Node(this.host.intern(this.obj.appendChild((child as any).obj)), this.host); }
  children(): Node[] { return this.obj.children().map((__x: any) => new Node(this.host.intern(__x), this.host)); }
  replaceChildren(nodes: Node[]): void { this.obj.replaceChildren(nodes.map((__x) => (__x as any).obj)); }
  firstChild(): Node | null { const __r = this.obj.firstChild(); return (__r === null ? null : new Node(this.host.intern(__r), this.host)); }
  static fromDocument(host: Host): Node { return new Node(host.intern((globalThis as any)["Node"].fromDocument()), host); }
}
