import { createHash } from 'crypto';
import { providerRegistry } from './providers/registry';
import { tokenCounter } from '@promptforge/token-counter';
import { cache, RedisKeys } from '@promptforge/redis';
import { buildMetaPrompt } from './meta-prompt';
import { scorePrompt } from './scorer';
import { parseStructure } from './structurer';
import { OptimizationError } from '@promptforge/errors';
import { logger } from '@promptforge/logger';
import type { OptimizationInput, OptimizationResult } from '@promptforge/types';
import { PLAN_LIMITS } from '@promptforge/config';

export class PromptOptimizer {
  async optimize(input: OptimizationInput): Promise<OptimizationResult> {
    const { prompt, targetModel, userId, tier } = input;

    // 1. Basic validation
    const trimmed = prompt.trim();
    if (trimmed.length < 10) {
      throw new OptimizationError('PROMPT_TOO_SHORT', 'Prompt must be at least 10 characters');
    }

    const planConfig = PLAN_LIMITS[tier];
    const roughTokens = tokenCounter.roughCount(trimmed);
    if (roughTokens > planConfig.maxPromptTokens) {
      throw new OptimizationError(
        'PROMPT_TOO_LONG',
        `Prompt exceeds ${planConfig.maxPromptTokens} token limit for your plan`,
      );
    }

    // 2. Check cache
    const promptHash = createHash('sha256').update(trimmed + targetModel).digest('hex').slice(0, 16);
    const cacheKey = RedisKeys.optimizationCache(promptHash);
    const cached = await cache.get<OptimizationResult>(cacheKey);

    if (cached) {
      logger.info({ event: 'optimization_cache_hit', userId, promptHash });
      return { ...cached, fromCache: true };
    }

    // 3. Count original tokens
    const originalTokens = tokenCounter.count(trimmed, targetModel);

    // 4. Build meta-prompt and call AI
    const systemPrompt = buildMetaPrompt(targetModel);
    const start = performance.now();

    const aiResult = await providerRegistry.completeWithFallback(
      systemPrompt,
      trimmed,
      targetModel,
    );

    const latencyMs = Math.round(performance.now() - start);

    // 5. Validate AI output
    const optimizedText = aiResult.text.trim();
    if (optimizedText.length < 10) {
      throw new OptimizationError('INVALID_OUTPUT', 'AI returned unusable result. Please try again.');
    }

    // Reject if AI just returned the original unchanged
    if (optimizedText === trimmed) {
      throw new OptimizationError('NO_IMPROVEMENT', 'Could not improve this prompt. Try adding more context.');
    }

    // 6. Calculate metrics
    const optimizedTokens = tokenCounter.count(optimizedText, targetModel);
    const savingsPct = ((originalTokens - optimizedTokens) / Math.max(originalTokens, 1)) * 100;

    const score = scorePrompt({
      original: trimmed,
      optimized: optimizedText,
      originalTokens,
      optimizedTokens,
      targetModel,
    });

    const structure = parseStructure(optimizedText);

    const result: OptimizationResult = {
      optimized: optimizedText,
      originalTokens,
      optimizedTokens,
      savingsPct: Math.round(savingsPct * 100) / 100,
      score,
      provider: aiResult.provider,
      model: aiResult.model,
      structure,
      latencyMs,
      fromCache: false,
    };

    // 7. Cache result (24h)
    await cache.set(cacheKey, result, 86_400);

    logger.info({
      event: 'optimization_complete',
      userId,
      targetModel,
      originalTokens,
      optimizedTokens,
      savingsPct: result.savingsPct,
      score,
      provider: aiResult.provider,
      latencyMs,
    });

    return result;
  }
}

export const promptOptimizer = new PromptOptimizer();
