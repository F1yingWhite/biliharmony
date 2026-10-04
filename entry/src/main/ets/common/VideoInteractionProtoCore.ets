import { util } from '@kit.ArkTS';
import { VideoInteractionCommand } from '../model/video/VideoInteractionModels';

@Sendable
export class SendableVideoCommand implements VideoInteractionCommand {
  id: string = '';
  oid: string = '';
  mid: string = '';
  command: string = '';
  content: string = '';
  progress: number = 0;
  extra: string = '';
}

/** Strict wire reader: HTTP 200 JSON/HTML and truncated messages must fail rather than look empty. */
class ViewProtoReader {
  private bytes: Uint8Array;
  private position: number = 0;

  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
  }

  eof(): boolean { return this.position === this.bytes.length; }

  decimal(): string {
    const groups: Array<number> = [];
    for (let index: number = 0; index < 10; index++) {
      if (this.position >= this.bytes.length) throw new Error('Truncated protobuf varint');
      const byte: number = this.bytes[this.position++];
      if (index === 9 && byte > 1) throw new Error('Invalid protobuf varint');
      groups.push(byte & 127);
      if ((byte & 128) === 0) {
        let digits: Array<number> = [0];
        for (let group: number = groups.length - 1; group >= 0; group--) {
          let carry: number = groups[group];
          for (let digit: number = 0; digit < digits.length; digit++) {
            const value: number = digits[digit] * 128 + carry;
            digits[digit] = value % 10;
            carry = Math.floor(value / 10);
          }
          while (carry > 0) { digits.push(carry % 10); carry = Math.floor(carry / 10); }
        }
        return digits.reverse().join('');
      }
    }
    throw new Error('Invalid protobuf varint');
  }

  number(): number { return Number(this.decimal()); }

  tag(): number {
    const tag: number = this.number();
    if (!Number.isSafeInteger(tag) || tag <= 0 || tag > 4294967295) throw new Error('Invalid protobuf tag');
    return tag;
  }

  take(length: number): Uint8Array {
    if (!Number.isSafeInteger(length) || length < 0 || this.position + length > this.bytes.length) {
      throw new Error('Truncated protobuf field');
    }
    const bytes: Uint8Array = this.bytes.subarray(this.position, this.position + length);
    this.position += length;
    return bytes;
  }

  message(): Uint8Array { return this.take(this.number()); }
  string(): string { return util.TextDecoder.create('utf-8').decodeToString(this.message()); }

  skip(wire: number): void {
    if (wire === 0) this.decimal();
    else if (wire === 1) this.take(8);
    else if (wire === 2) this.message();
    else if (wire === 5) this.take(4);
    else throw new Error('Invalid protobuf wire type');
  }
}

function decodeCommand(bytes: Uint8Array): SendableVideoCommand {
  const reader: ViewProtoReader = new ViewProtoReader(bytes);
  const command: SendableVideoCommand = new SendableVideoCommand();
  let id: string = '';
  while (!reader.eof()) {
    const tag: number = reader.tag();
    const field: number = tag >>> 3;
    const wire: number = tag & 7;
    if (wire === 0 && field === 1) id = reader.decimal();
    else if (wire === 0 && field === 2) command.oid = reader.decimal();
    else if (wire === 0 && field === 3) command.mid = reader.decimal();
    else if (wire === 0 && field === 6) command.progress = reader.number();
    else if (wire === 2 && field === 4) command.command = reader.string();
    else if (wire === 2 && field === 5) command.content = reader.string();
    else if (wire === 2 && field === 9) command.extra = reader.string();
    else if (wire === 2 && field === 10) command.id = reader.string();
    else reader.skip(wire);
  }
  if (command.id.length === 0) command.id = id;
  return command;
}

/** DmWebViewReply field 9 contains repeated CommandDm. Other fields are skipped for schema compatibility. */
export function decodeVideoInteractionViewBuffer(buffer: ArrayBuffer): Array<SendableVideoCommand> {
  const reader: ViewProtoReader = new ViewProtoReader(new Uint8Array(buffer));
  const commands: Array<SendableVideoCommand> = [];
  while (!reader.eof()) {
    const tag: number = reader.tag();
    const field: number = tag >>> 3;
    const wire: number = tag & 7;
    if (field === 9 && wire === 2) commands.push(decodeCommand(reader.message()));
    else reader.skip(wire);
  }
  return commands;
}
