import type { Host } from "@midstall/webidl-runtime";

export class EventTarget {
  constructor(readonly handle: number, private host: Host) {}
  private get obj(): any { return this.host.value(this.handle); }
  static readonly CONNECTING: number = 0;
  get url(): string { return this.obj.url; }
  addEventListener(type: string): void { this.obj.addEventListener(type); }
}

export type ReadyState = "connecting" | "open" | "closed";

export interface RequestInit {
  method: string;
  timeout?: number;
}
