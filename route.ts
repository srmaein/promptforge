import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { createClient } from '@/lib/supabase/server';
import { promptOptimizer } from '@promptforge/ai-engine';
import { cache, forgeRatelimit, RedisKeys } from '@promptforge/redis';
import { checkUsageLimit, incrementUsage, getMonthKey, getUserPlan, saveOptimization } from '@promptforge/db';
import { analyticsQueue, referralQueue } from '@promptforge/queue';
import { handleApiError, AuthError, UsageLimitError, PlanGateError, RateLimitError, ConflictError } from '@promptforge/errors';
import { isModelAllowed, PLAN_LIMITS } from '@promptforge/config';
import { logger } from '@promptforge/logger';
import type { TargetModel } from '@promptforge/config';

export const runtime = 'nodejs';
export const maxDuration = 60;

const ForgeSchema = z.object({
  prompt: z.string().min(10, 'Prompt too short').max(32_000, 'Prompt too long'),
  targetModel: z.enum([
    'gpt-4o', 'gpt-4o-mini', 'gpt-4-turbo', 'gpt-3.5-turbo',
    'gemini-1.5-pro', 'gemini-1.5-flash', 'gemini-2.0',
    'claude-3-5-sonnet', 'claude-3-opus', 'claude-3-haiku',
    'general',
  ]),
});

export async function POST(req: NextRequest) {
  let userId: string | null = null;

  try {
    // 1. Parse body
    const body = ForgeSchema.parse(await req.json());

    // 2. Auth
    const supabase = createClient();
    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) throw new AuthError();
    userId = user.id;

    // 3. Per-user rate limit
    const { success: rateOk } = await forgeRatelimit.limit(user.id);
    if (!rateOk) throw new RateLimitError(60);

    // 4. Plan check
    const { plan } = await getUserPlan(user.id);
    if (!isModelAllowed(body.targetModel as TargetModel, plan)) {
      throw new PlanGateError('pro');
    }

    // 5. Usage limit
    const { allowed, used, limit } = await checkUsageLimit(user.id, plan);
    if (!allowed) throw new UsageLimitError(used, limit);

    // 6. Concurrency lock
    const lockKey = RedisKeys.forgeLock(user.id);
    const locked = await cache.acquireLock(lockKey, 30);
    if (!locked) throw new ConflictError('Another optimization is already in progress');

    // 7. Stream response
    const encoder = new TextEncoder();
    const { readable, writable } = new TransformStream();
    const writer = writable.getWriter();

    const sendEvent = async (data: unknown) => {
      await writer.write(encoder.encode(`data: ${JSON.stringify(data)}\n\n`));
    };

    (async () => {
      try {
        await sendEvent({ type: 'progress', step: 'analyzing', pct: 10 });

        const result = await promptOptimizer.optimize({
          prompt: body.prompt,
          targetModel: body.targetModel as TargetModel,
          userId: user.id,
          tier: plan,
        });

        await sendEvent({ type: 'progress', step: 'saving', pct: 85 });

        // Persist to DB
        if (!result.fromCache) {
          const saved = await saveOptimization({
            userId: user.id,
            originalPrompt: body.prompt,
            targetModel: body.targetModel,
            result,
          });

          // Increment usage
          await incrementUsage(user.id, getMonthKey());

          // Fire async side-effects
          await analyticsQueue.add('analytics', {
            event: 'optimization_complete',
            userId: user.id,
            properties: {
              model: body.targetModel,
              savingsPct: result.savingsPct,
              score: result.score,
              plan,
              fromCache: false,
            },
          });

          await referralQueue.add('referral', {
            userId: user.id,
            action: 'check_activation',
          });
        }

        await sendEvent({ type: 'result', data: result });
        await sendEvent({ type: 'done' });

      } catch (err) {
        logger.error({ event: 'forge_stream_error', userId, err });
        await sendEvent({
          type: 'error',
          message: err instanceof Error ? err.message : 'Optimization failed',
          code: (err as { code?: string }).code,
        });
      } finally {
        await cache.releaseLock(RedisKeys.forgeLock(userId!));
        await writer.close();
      }
    })();

    return new Response(readable, {
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache, no-transform',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no',
      },
    });

  } catch (err) {
    if (userId) await cache.releaseLock(RedisKeys.forgeLock(userId));
    return handleApiError(err);
  }
}
