package org.springframework.samples.petclinic.model;

/**
 * Canary comment deliberately contains enough readable prose to require a conservative line wrap during autonomous runner discovery validation
 * discovery validation without changing any production source file.
 */
/*
 * Ordinary block comment deliberately contains enough readable prose to look wrappable but must not be promoted as a Javadoc cleanup candidate
 */
class CanaryCommentModel {

	private static final String TEXT_BLOCK = """
			/**
			 * Text block content deliberately contains enough readable prose to look wrappable but must not be promoted as a Javadoc cleanup candidate
			 */
			""";
}
