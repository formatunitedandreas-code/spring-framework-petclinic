package org.springframework.samples.petclinic.repository.jdbc;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.BDDMockito.given;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

import org.junit.jupiter.api.Test;
import org.springframework.dao.IncorrectResultSizeDataAccessException;
import org.springframework.jdbc.core.RowMapper;

class OneToManyResultSetExtractorTests {

    @Test
    void emptyResultSetReturnsNoRootsForAnyExpectedResults() throws Exception {
        ResultSet rs = rows();

        List<Root> results = extractor(OneToManyResultSetExtractor.ExpectedResults.ANY).extractData(rs);

        assertThat(results).isEmpty();
        verify(rs, times(1)).next();
    }

    @Test
    void singleRootWithoutChildrenIsPreserved() throws Exception {
        ResultSet rs = rows(row(1, null));

        List<Root> results = extractor(OneToManyResultSetExtractor.ExpectedResults.ANY).extractData(rs);

        assertThat(results).containsExactly(root(1));
        verify(rs, times(2)).next();
    }

    @Test
    void singleRootWithMultipleChildrenPreservesRootAndChildOrder() throws Exception {
        ResultSet rs = rows(row(1, 1, "Basil"), row(1, 1, "Zelda"));

        List<Root> results = extractor(OneToManyResultSetExtractor.ExpectedResults.ANY).extractData(rs);

        assertThat(results).containsExactly(root(1, "Basil", "Zelda"));
        verify(rs, times(3)).next();
    }

    @Test
    void multipleRootsPreserveCursorProgressionAndMapperRowIndexes() throws Exception {
        ResultSet rs = rows(row(1, 1, "Basil"), row(1, 1, "Zelda"), row(2, null), row(3, 3, "Iggy"));
        TestExtractor extractor = extractor(OneToManyResultSetExtractor.ExpectedResults.ANY);

        List<Root> results = extractor.extractData(rs);

        assertThat(results).containsExactly(root(1, "Basil", "Zelda"), root(2), root(3, "Iggy"));
        assertThat(extractor.rootRows).containsExactly(1, 3, 4);
        assertThat(extractor.childRows).containsExactly(1, 2, 4);
        verify(rs, times(5)).next();
    }

    @Test
    void oneAndOnlyOneRejectsMultipleRoots() throws Exception {
        ResultSet rs = rows(row(1, null), row(2, null));

        assertThatThrownBy(() -> extractor(OneToManyResultSetExtractor.ExpectedResults.ONE_AND_ONLY_ONE).extractData(rs))
            .isInstanceOf(IncorrectResultSizeDataAccessException.class)
            .hasMessageContaining("Incorrect result size: expected 1, actual 2");
    }

    @Test
    void oneOrNoneRejectsMultipleRoots() throws Exception {
        ResultSet rs = rows(row(1, null), row(2, null));

        assertThatThrownBy(() -> extractor(OneToManyResultSetExtractor.ExpectedResults.ONE_OR_NONE).extractData(rs))
            .isInstanceOf(IncorrectResultSizeDataAccessException.class)
            .hasMessageContaining("Incorrect result size: expected 1, actual 2");
    }

    @Test
    void atLeastOneRejectsEmptyResultSet() throws Exception {
        ResultSet rs = rows();

        assertThatThrownBy(() -> extractor(OneToManyResultSetExtractor.ExpectedResults.AT_LEAST_ONE).extractData(rs))
            .isInstanceOf(IncorrectResultSizeDataAccessException.class)
            .hasMessageContaining("Incorrect result size: expected 1, actual 0");
    }

    private TestExtractor extractor(OneToManyResultSetExtractor.ExpectedResults expectedResults) {
        return new TestExtractor(expectedResults);
    }

    private ResultSet rows(Row... rows) throws SQLException {
        ResultSet rs = mock(ResultSet.class);
        AtomicInteger currentRow = new AtomicInteger(-1);
        given(rs.next()).willAnswer(invocation -> currentRow.incrementAndGet() < rows.length);
        given(rs.getInt("root_id")).willAnswer(invocation -> rows[currentRow.get()].rootId());
        given(rs.getObject("child_fk")).willAnswer(invocation -> rows[currentRow.get()].childForeignKey());
        given(rs.getString("child_name")).willAnswer(invocation -> rows[currentRow.get()].childName());
        return rs;
    }

    private Row row(int rootId, Integer childForeignKey) {
        return row(rootId, childForeignKey, null);
    }

    private Row row(int rootId, Integer childForeignKey, String childName) {
        return new Row(rootId, childForeignKey, childName);
    }

    private Root root(int id, String... children) {
        Root root = new Root(id);
        root.children().addAll(List.of(children));
        return root;
    }

    private record Row(int rootId, Integer childForeignKey, String childName) {
    }

    private record Root(int id, List<String> children) {

        Root(int id) {
            this(id, new ArrayList<>());
        }
    }

    private final class TestExtractor extends OneToManyResultSetExtractor<Root, String, Integer> {

        private final List<Integer> rootRows;

        private final List<Integer> childRows;

        private TestExtractor(ExpectedResults expectedResults) {
            this(expectedResults, new ArrayList<>(), new ArrayList<>());
        }

        private TestExtractor(ExpectedResults expectedResults, List<Integer> rootRows, List<Integer> childRows) {
            super(rootMapper(rootRows), childMapper(childRows), expectedResults);
            this.rootRows = rootRows;
            this.childRows = childRows;
        }

        @Override
        protected Integer mapPrimaryKey(ResultSet rs) throws SQLException {
            return rs.getInt("root_id");
        }

        @Override
        protected Integer mapForeignKey(ResultSet rs) throws SQLException {
            return (Integer) rs.getObject("child_fk");
        }

        @Override
        protected void addChild(Root root, String child) {
            root.children().add(child);
        }

        private static RowMapper<Root> rootMapper(List<Integer> rootRows) {
            return (rs, rowNum) -> {
                rootRows.add(rowNum);
                return new Root(rs.getInt("root_id"));
            };
        }

        private static RowMapper<String> childMapper(List<Integer> childRows) {
            return (rs, rowNum) -> {
                childRows.add(rowNum);
                return rs.getString("child_name");
            };
        }
    }
}
