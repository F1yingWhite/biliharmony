import { taskpool } from '@kit.ArkTS';
import { decodeVideoInteractionViewBuffer, SendableVideoCommand } from './VideoInteractionProtoCore';

@Concurrent
function decodeViewTask(buffer: ArrayBuffer): Array<SendableVideoCommand> {
  return decodeVideoInteractionViewBuffer(buffer);
}

export async function decodeVideoInteractionView(buffer: ArrayBuffer): Promise<Array<SendableVideoCommand>> {
  return await taskpool.execute(decodeViewTask, buffer) as Array<SendableVideoCommand>;
}
