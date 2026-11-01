import { assertEquals } from "jsr:@std/assert@1";
import {
  conditionWords,
  skyWords,
  weatherSentence,
  windWords,
} from "./metar_words.ts";

Deno.test("sky words follow the thickest layer", () => {
  assertEquals(skyWords([]), "Clear skies");
  assertEquals(skyWords([{ cover: "CLR", baseFt: null }]), "Clear skies");
  assertEquals(skyWords([{ cover: "FEW", baseFt: 3000 }]), "A few clouds");
  assertEquals(
    skyWords([{ cover: "FEW", baseFt: 900 }, { cover: "BKN", baseFt: 4000 }]),
    "Mostly cloudy",
  );
  assertEquals(skyWords([{ cover: "OVC", baseFt: 800 }]), "Overcast");
  assertEquals(skyWords([{ cover: "VV", baseFt: 100 }]), "Sky obscured");
});

Deno.test("present weather wins over the sky", () => {
  assertEquals(
    conditionWords("-RA BR", [{ cover: "OVC", baseFt: 800 }]),
    "Light rain and mist",
  );
  assertEquals(
    conditionWords("", [{ cover: "SCT", baseFt: 8000 }]),
    "Partly cloudy",
  );
});

Deno.test("wind words and the sentence", () => {
  assertEquals(windWords(null, null), null);
  assertEquals(windWords(0, null), "calm winds");
  assertEquals(windWords(8, null), "light winds");
  assertEquals(windWords(15, null), "a steady breeze");
  assertEquals(windWords(24, null), "strong winds");
  assertEquals(windWords(14, 27), "gusty winds");
  assertEquals(
    weatherSentence(null, [], 5, null),
    "Clear skies with light winds.",
  );
  assertEquals(weatherSentence(null, [], null, null), "Clear skies.");
});
